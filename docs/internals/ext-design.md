# The extension target: loading Spinel-compiled code from CRuby

> A **design document**: Part I records what the tree does today (the code,
> the Makefile and the tests cite this file by the names used here), Part II
> is the design for the next stages and has not been implemented. Nothing in
> Part II is a user promise; the user-facing contract is the
> [Extensions](../spin.md#extensions-a-ruby-kernel-compiled-into-a-cruby-native-extension)
> section of spin.md.

## The question

"A binary CRuby can `require`" means one thing on every platform CRuby runs
on: a shared object (`.so` / `.bundle` / `.dll`) that exports one function,
`Init_<feature>`, built against the headers of the Ruby that will load it
and using nothing but that Ruby's public C API. CRuby has no other ABI for
loaded code. There is no stable layout of `RString` or `RArray` across
versions, no way to link against the VM's internals, and no way to hand the
VM a foreign object: everything a loaded library gives Ruby goes through
`rb_*` calls on the host's own `VALUE`s.

So the problem is not "make Spinel's binary match an ABI". Spinel's runtime
(`lib/`) stays exactly what it is: a second, private world with its own
heap, collector, strings and exception stack. The problem is the **boundary**
between that world and the host's: which values cross, in which direction,
who owns what, what happens when either side raises, and how the two
collectors and the GVL are kept out of each other's way. Spinel already
builds such a boundary for the narrow case (Part I). Part II widens it.

## Part I: what exists

### Layer 1: a host-callable library (`--ext-init`, `--ext-entry`)

```
spinel kernel.rb -c --ext-init Init_k --ext-entry ExtKernel.triple,ExtKernel.total -o k.c
```

writes `k.c` and `k.h`. The translation unit is the ordinary one with three
differences (`src/codegen.c`, `emit_program`'s `g_ext_init_name` arms):

- `void Init_k(void)` replaces `main`. It runs the program's top level (so
  constants, class bodies and `at_exit` registrations happen) except the
  `if __FILE__ == $0` block, which the parser marks `program_guard`. That
  block is the kernel's manual test driver *and* the call-site type source
  for the entries: inference consumes it, the emitted init drops it.
- The `--ext-entry` methods are inference roots (`analyze.c`, the reachability
  BFS), so dead-code elimination keeps them, and they are emitted non-static
  under their real C signature: `sp_int sp_ExtKernel_s_triple(sp_int)`,
  `sp_oint sp_ExtKernel_s_find_pos(sp_IntArray *, sp_int)`. A nullable
  Integer or Float slot is `sp_oint` / `sp_ofloat` ([FFI.md](../FFI.md)).
- `int Init_k_try(void (*fn)(void *), void *ctx, const char **cls, const char **msg)`
  runs `fn` under a frame of the runtime's exception stack and answers a
  raise as its class name and message, so a host never touches
  `sp_exc_stack` or the root stack itself.

The header `k.h` is the contract: `#define SPINEL_EXT_HOST 1`, the runtime
include, the init and try prototypes, and one prototype per entry. A host
compiled against it fails to build when a signature drifts, instead of
reinterpreting bytes. `SPINEL_EXT_HOST` / `SPINEL_EXT_KERNEL`
(`lib/spinel_rt.h`) turn the runtime's per-program statics (`sp_argv`, the
pending-exception slots, `sp_sym_to_s`, `sp_class_to_s`, ...) into
`extern` declarations on the host side and definitions on the kernel side,
so the two translation units share one runtime instance.

`test/ext/host.c` is the pure-C host, `make ext-test` runs it.

### Layer 2: the CRuby shim (`--ext cruby`) and `spin ext`

`--ext cruby` adds `k_ext.c` (`ext_generate_cruby_shim`, `src/codegen.c`):
the mechanization of a hand-written shim ("M0") over Layer 1.

- `Init_<feature>` (feature = the output's basename) calls `Init_k`, makes
  a Ruby `Mutex`, and for each entry `rb_define_module(name)` +
  `rb_define_module_function(m, "triple", spx_m_N, arity)`.
- A call is `rb_mutex_synchronize(lock, ...)` around
  `rb_ensure(convert + run, restore root count)`. Arguments convert under
  the GVL into fresh Spinel values, each rooted by hand for the whole call;
  the kernel body runs through `rb_thread_call_without_gvl` inside
  `Init_k_try`; the result converts back under the GVL.
- A kernel raise re-raises as `Object.const_get(cls)` with the message
  (`RuntimeError` when the constant is not a class; a name the host does
  not have at all makes the lookup itself raise `NameError`, see below).

`spin ext new NAME` scaffolds a gem (kernel in `lib/NAME/kernel.rb`,
loader that `require`s the extension and falls back to the kernel source,
`extconf.rb` with `-I$(srcdir)`, a differential test); `spin ext build`
runs the compiler and vendors `lib/*.c`, `lib/*.h` and the regexp engine
flat into `ext/NAME/`; `spin ext test` builds the `.so` with the host's
headers and runs every case through the pure kernel and the compiled one.
`make ext-cruby-test` is the in-tree run (`test/ext/driver.rb`), including
concurrent callers, interrupts and GC stress.

### The boundary rules as coded

The compiler enforces these at compile time, naming the entry:

| Rule | What | Where |
|---|---|---|
| v1 arity | fixed positional parameters only: no `*rest`, `**kw`, `&blk`, no `yield` | `ext_generate_cruby_shim` |
| v1 owner | an entry is `def self.m` of a module; a subclass-dispatched class method is not an entry | same |
| v1 types | `Integer`, `Float`, `bool`, `String`, `Array[Integer]`, `Array[Float]`, `Array[String]`, and nullable `Integer`/`Float` (`sp_oint`); the return may also be `nil`/void | `ext_rb_in` / `ext_rb_out` |
| R4 | values cross by **copy**, so a mutation of a parameter (`a.sort!`, `s << x`, `a[i] = v`) is refused: the caller would not see it and the divergence from CRuby would be silent | `ext_refuse_param_mutation` |
| R6 | one call at a time, off the GVL, under a Ruby `Mutex` (a pthread mutex waited on under the GVL would deadlock against the other caller's GVL reacquisition) | the shim |
| R7 | a raise crosses as (class name, message) through the try helper | the shim, `Init_k_try` |

At run time the shim raises `TypeError` for a wrong argument class,
`RangeError` for a Bignum, `ArgumentError` for a String whose encoding is
not UTF-8, US-ASCII or binary; kernel Strings come back UTF-8.

### What does not cross, and what is unsafe today

Measured against "a library a CRuby program can use like any other", the
v1 boundary leaves out, in rough order of how often a user would hit it:

1. **Objects and classes.** A kernel class is invisible to the host; an
   instance cannot be an argument or a return. Everything is a module
   function over scalars and flat arrays.
2. **`Symbol`, `Hash`, nested or mixed `Array`, `Range`, `nil` in a
   pointer slot** (a `String` parameter the kernel accepts `nil` for still
   raises `TypeError` at the shim: only `sp_oint`/`sp_ofloat` carry a nil).
3. **Blocks, `*rest`, keywords, optional parameters.**
4. **Kernel constants and exception classes.** `TOPLEVEL_NOTE` in
   `test/ext/kernel.rb` exists on the Spinel side only (`defined?` on the
   host answers nil). A `raise Boom` where `Boom` is the kernel's own
   class arrives as **`NameError: uninitialized constant KNil::Boom`**: the
   shim's `const_get` raises before anything is re-raised, so the host
   cannot even `rescue RuntimeError` it. (Probed with a kernel whose
   `KNil::Boom < StandardError`.)
5. **`exit` / `abort` lose their status.** Inside a try frame
   `sp_exit_raise` (`lib/spinel_rt.h`) raises `SystemExit` rather than
   calling `exit(3)`, so the host does get a `SystemExit`, but the shim
   rebuilds it from the name and message: `exit(3)` arrives with
   `status == 0` and the message `"exit"`, `abort("m")` with `status == 0`.
   The kernel's `at_exit` blocks run at the **end of `require`**
   (`sp_at_exit_run` is emitted at the end of the init function), not at
   process exit; probed through stderr: `kernel toplevel ran`,
   `kernel at_exit ran`, `after require`.
6. **Two Spinel extensions in one process give wrong answers.** CRuby's
   `require` dlopens with `RTLD_GLOBAL`, and every runtime symbol and every
   non-static symbol of the kernel TU has default visibility, so the second
   extension's calls to `sp_sym_to_s`, `sp_class_to_s`, `sp_gc_alloc` and
   the rest bind to the first extension's definitions. Probed with two
   kernels, `MA` (symbols `:alpha, :beta`, class `Pa`) and `MB` (`:gamma,
   :delta, :eps`, classes `Qb`, `Rb`), each correct alone; loaded together,
   `MB.name_of(0)` answers `"alpha"`, `MB.name_of(2)` answers `""`,
   `MB.cls(0)` answers `"MA::Pa"`. Both extensions rebuilt with every TU
   (the vendored runtime included) at `-fvisibility=hidden`, linked
   `-Wl,-Bsymbolic`, and only `Init_*` marked default, answer correctly in
   either load order under `SPINEL_GC_STRESS=2`. The one symbol still
   exported after that is `sp_ctx_swap`, the hand-written assembly context
   switch, which needs a `.hidden` directive of its own.
7. **A kernel that uses `Thread`.** Nothing refuses it, and a kernel that
   spawns threads under a `Mutex` builds and answers correctly from Ruby
   3.3 (the generated TU is compiled `-DSP_THREADS`, `Init_k` calls
   `sp_sched_init`). What that puts inside the host process: the
   scheduler's OS workers and monitor thread, and a `sigaction` handler on
   `SIGURG` (`SA_RESTART`) that the monitor fires at workers with
   `pthread_kill`; the stop-the-world collector parks the workers it knows,
   and knows nothing of the host's threads, which is fine only while every
   kernel object stays on the kernel side (true today, false once objects
   cross by reference). A host program that traps `SIGURG` itself, or a
   second Spinel extension with threads, share one handler slot.
8. **The stack.** A kernel entry runs on the calling Ruby thread's machine
   stack: 8 MB on the main thread, **1 MB** on a `Thread.new` thread
   (`RubyVM::DEFAULT_PARAMS[:thread_machine_stack_size]`). A standalone
   Spinel program runs on a stack it maps itself (`sp_main_stack_run`,
   `SPINEL_MAIN_STACK`); a recursive kernel that is fine as a program can
   overflow when called from a Ruby thread.
9. **`puts` in a kernel** writes through C stdio while the host's `$stdout`
   has its own buffer; the two interleave by buffer size, not by program
   order. Probed with stdout a pipe: `host 1`, `host 2`, `host 3`, then
   `kernel: a`, `kernel: b` at process exit.
10. **Bignum, encodings, backtraces.** `--int-overflow=promote` values have
    no crossing; a String's encoding is not carried back; a kernel
    exception's backtrace is not attached to the host exception.

Item 6 is a correctness hole in what already ships, 4 and 5 are wrong
answers on paths a user will hit, 7 is a risk: they come first in Part
II's phasing, ahead of any new feature. (Every probe above was run with
the compiler built from this tree against Ruby 3.3.6; `make
ext-cruby-test`'s driver passes there too, the Makefile's 4.0 gate is
about a hang seen under 3.2.)

## Part II: the design

### Goals

- A kernel's **classes and objects** are usable from the host: `new`,
  instance methods, readers and writers, identity, `is_a?`, `inspect`,
  the kernel's exception classes rescuable by name.
- **Blocks** cross inward: a host block becomes the kernel's block.
- Everything that cannot cross is a **compile-time refusal** that names the
  entry and the slot; nothing degrades silently (the same stance as R4).
- The emitted extension uses the host Ruby's **public C API only**, is
  built by the host's `mkmf` with the host's flags, and coexists with any
  number of other extensions, Spinel-built or not.
- The kernel keeps Spinel's semantics and speed inside a call; the
  differential test (`spin ext test`) stays the oracle for parity.

Non-goals: sharing a heap with CRuby; running two kernel entries in parallel
(a later stage, [§Threads](#threads-the-gvl-and-the-lock)); exporting a
kernel `Proc` to the host; metaprogramming across the boundary
(`define_method`, `method_missing`, `send` with a computed name).

### Ways considered

| | A. Copy boundary (today) | B. Handle boundary (this design) | C. Native-`VALUE` codegen | D. One heap: kernel objects as CRuby `T_DATA` |
|---|---|---|---|---|
| What crosses | scalars, flat arrays, by copy | A plus objects by reference (a wrapper owns a pinned kernel object), blocks inward, Hash/Symbol/nested arrays by copy | everything: the kernel *is* C-API code over host objects | everything by reference; a kernel `String` is a kernel object the host wraps |
| Kernel semantics | Spinel's | Spinel's | CRuby's (the runtime is gone) | Spinel's, allocation through CRuby |
| Speed inside a call | Spinel's | Spinel's | CRuby's allocation, boxing and GC; only unboxed scalars stay fast | Spinel's code over CRuby's allocator; every allocation needs the GVL |
| Boundary cost | O(size) per argument | O(1) per object, O(size) per copied container | none | none |
| GC | two collectors, disjoint graphs | two collectors, the only edges are pins counted on both sides | one | one, but every `scan` function becomes a `dmark` and the Spinel collector is a second code path for the same types |
| GVL | released around the call | per-entry policy (hold by default) | held always | held always |
| Effort | shipped | shim generator + a root table + class mirroring: additive to codegen | a second code generator and a second runtime: a fork of the project | a second allocation mode through the whole runtime |

C is the only option that makes a kernel *exactly* CRuby, and it does so by
removing the thing the project exists for. It remains the right answer for
a different product (a typed C-extension generator) and is not pursued
here. D removes the dual-collector problem at the cost of rewriting the
allocator and losing off-GVL execution; it would be revisited only if
copying containers at the boundary proved to be the dominant cost in real
kernels, which nothing so far shows. B is additive to A: the copy table
stays as it is, and the new kinds are added beside it.

### A worked example

```ruby
# lib/fast_geo/kernel.rb
module FastGeo
  class Error < StandardError; end

  class Vec
    attr_reader :x, :y
    def initialize(x, y)
      @x = x
      @y = y
    end
    def +(o) = Vec.new(@x + o.x, @y + o.y)
    def norm = Math.sqrt(@x * @x + @y * @y)
    def each_coord
      yield @x
      yield @y
    end
    def to_s = "(#{@x}, #{@y})"
  end

  def self.centroid(vs)
    raise Error, "empty" if vs.empty?
    s = vs.reduce(Vec.new(0.0, 0.0)) { |a, v| a + v }
    Vec.new(s.x / vs.length, s.y / vs.length)
  end
end

if __FILE__ == $0
  v = FastGeo::Vec.new(1.0, 2.0)
  p FastGeo.centroid([v, v + v]).norm
  v.each_coord { |c| p c }
end
```

```toml
[ext]
module  = "FastGeo"
classes = ["FastGeo::Vec", "FastGeo::Error"]
entries = ["FastGeo.centroid", "FastGeo::Vec.new", "FastGeo::Vec#+",
           "FastGeo::Vec#norm", "FastGeo::Vec#x", "FastGeo::Vec#y",
           "FastGeo::Vec#each_coord", "FastGeo::Vec#to_s"]
```

From the host:

```ruby
require "fast_geo"
v = FastGeo::Vec.new(1.0, 2.0)        # a wrapper around a kernel object
w = v + v                             # kernel dispatch; a new wrapper
FastGeo.centroid([v, w]).norm         # the Array of wrappers crosses as Array[Vec]
v.each_coord { |c| puts c }           # the block runs on the host, under the GVL
FastGeo.centroid([])                  # => raises FastGeo::Error, "empty"
v.is_a?(FastGeo::Vec)                 # => true (a real host class)
v.equal?(FastGeo.centroid([v]))       # identity: the same kernel object, the same wrapper
```

### The export surface

`[ext]` in `spin.toml` grows two keys and a spelling:

- `classes`: kernel classes (and exception classes) mirrored on the host.
  A class not listed is **opaque**: an instance of it cannot cross, and an
  entry whose signature needs one is refused naming the class.
- `entries`: `Mod.m` (today), plus `Cls.new`, `Cls#m`, `Cls#attr`,
  `Cls#attr=`. `Cls.*` / `Cls#*` export every public method whose
  signature can cross; the ones that cannot are reported as warnings
  (and refused under `--ext-strict`).
- Per-entry attributes, as a table: `[ext.entry."FastGeo.centroid"]` with
  `gvl = "release"` ([§Threads](#threads-the-gvl-and-the-lock)) and
  `stack = "16M"` ([§Stack](#the-stack)).

`--ext-entry` on the command line takes the same spellings; `--ext-class`
is the flag form of `classes`. The compiler's view is unchanged: an entry is
a reachability root whose call sites in the guard block type it.

### Values: the crossing table

Each entry's C signature is already known (Layer 1). The shim generator
selects, per slot, from this table. **Copy types** cross by value and keep
R4 (a mutation of such a parameter is refused). **Reference types** cross
by handle, and R4 does not apply to them: a kernel mutating an object it
was given is exactly what the host expects.

| Spinel type | host → kernel (`spx_in_*`) | kernel → host (`spx_out_*`) | notes |
|---|---|---|---|
| `Integer` (`sp_int`) | Fixnum; Bignum `RangeError` unless the slot is Bigint-promoted, then `rb_big2str` → `sp_bigint_from_str` | `LL2NUM`; a Bigint through `mpz_get_str` → `rb_cstr2inum` | 64-bit on every host this runs on |
| `Float` | `NUM2DBL` (Integer accepted, as `to_f`) | `DBL2NUM` | |
| `bool` | `RTEST` | `Qtrue`/`Qfalse` | |
| `nil` | a nullable slot: `sp_oint`/`sp_ofloat` as today; a nullable pointer slot takes `Qnil` as `NULL` | `Qnil` | *only* a slot inference marked nullable (the `nullable` field of `--emit-types`) accepts `Qnil`; others `TypeError` |
| `String` | UTF-8 / US-ASCII / binary bytes copied into a kernel String; other encodings `ArgumentError` (no transcoding) | `rb_utf8_str_new`, or `rb_str_new` (binary) when the kernel String is marked binary | the kernel has no encodings beyond that flag; a frozen literal crosses as a frozen host String |
| `Symbol` | `rb_sym2str` → `sp_sym_intern_n` | `sp_sym_to_s` → `rb_check_symbol_cstr` | the dynamic pool handles a name the program never spelled |
| `Array[T]` typed | per element as `T`, into `sp_IntArray` / `sp_FloatArray` / `sp_StrArray` / `sp_PtrArray` (of wrapped objects) | per element | as today for the three scalar kinds; `Array[Vec]` is new |
| `Array[untyped]` | recursive into `sp_PolyArray`; a cycle (`a << a`) is `ArgumentError` | recursive | depth bounded by the host's `rb_ary_*` recursion |
| `Hash[K, V]` typed | into `sp_StrIntHash` and the other typed hashes; keys in the typed kinds are `String`/`Integer`/`Symbol` | per pair, insertion order kept | |
| `Hash[untyped]` | recursive into the poly hash | recursive | default value / default proc do not cross (refused when the slot's type says the kernel reads them) |
| `Range` of Integer/Float/String | `rb_range_values` → the by-value kinds | `rb_range_new` | endless/beginless preserved |
| kernel object of an exported class | the wrapper's kernel pointer; a wrong class `TypeError` | the object's wrapper, made or found ([§Objects](#objects-wrappers-identity-and-classes)) | **reference** |
| kernel object of an unexported class | refused at compile time | refused | |
| host object (anything else) | a `HostRef` (opaque): allowed only where the kernel's slot is `untyped` and the kernel only stores or returns it | the referenced `VALUE` | **reference**; the kernel cannot call methods on it (no `send` across the boundary in this stage) |
| block (`&blk`, `yield`) | a kernel `sp_Proc` whose body re-enters the host ([§Blocks](#blocks-and-callbacks)) | a kernel Proc does not cross out: refused | inward only |
| `Struct`, `Time`, `Complex`, `Rational`, `Set`, `IO` | refused in this stage | refused | each is a later row, not a design change |

A kernel exception object crossing *out* is a special case of a kernel
object ([§Exceptions](#exceptions-in-both-directions)).

### Objects: wrappers, identity and classes

**Mirroring.** `Init_<feature>` defines each exported class with
`rb_define_class_under(outer, name, superclass)`, outer resolved by the
kernel's own nesting (`FastGeo::Vec` under `rb_define_module("FastGeo")`),
superclass the nearest *exported* ancestor, else `rb_cObject` (an exception
class: its nearest exported ancestor, else the builtin the kernel's
`sp_user_exc_parent_fn` table names, `StandardError` for a plain
`class Error < StandardError`). A kernel class whose ancestor chain crosses
an unexported class is refused: a host `is_a?` would answer wrongly. The
class's `inspect`/`name` is therefore the real one, `rescue FastGeo::Error`
works, and `FastGeo::Vec === v` is a plain host test.

**The wrapper.** An instance on the host is a `TypedData` object of the
mirrored class whose payload is the kernel object pointer and the
wrapper's own `VALUE`, under an `rb_data_type_t` per exported class:

```c
typedef struct { void *obj; VALUE self; } spx_wrap;
static const rb_data_type_t spx_type_Vec = {
  "FastGeo::Vec", { NULL /* dmark */, spx_release, spx_dsize, spx_compact },
  NULL, NULL, RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_WB_PROTECTED
};
```

No `dmark`: a kernel object never holds a host `VALUE` except through a
`HostRef`, which is marked from the shim's own table (below). `dfree`
(`spx_release`) drops the kernel-side pin. `dsize` answers the kernel
object's `sp_gc_hdr.size` so `ObjectSpace.memsize_of` is honest.
`dcompact` is what keeps identity right under `GC.compact`, below.

**Pins: the kernel side.** The shim owns a *pin table*: a growable array of
`sp_RbVal` with a free list, one slot per live wrapper, marked by a function
the shim chains onto `sp_gc_mark_globals_hook` the way `sp_sched_init`
chains the scheduler's (`lib/sp_sched.c`). A wrapper is made by taking a
slot; `dfree` frees it. The kernel collector therefore sees every object the
host still refers to as a root, and nothing else. The root *stack*
(`SP_GC_ROOT`) keeps its current role: the in-flight values of one call.

**Identity.** Returning the same kernel object twice must answer the same
wrapper, or `equal?`, `Hash` keys and `ObjectSpace::WeakMap` on the host
all break. Each exported class's generated struct gets a `VALUE wrapper`
field after its `cls_id` (the same device as `sp_cext_data`'s prefix for
the recorder's data classes). `spx_out_obj(p)` answers `p->wrapper` when
non-zero, else allocates one, stores it and pins. `spx_release` clears the
field as it drops the pin. The field is never marked by either collector:
when the host wrapper dies, `dfree` runs before anything could observe the
dangling word, and a kernel object that outlives its wrapper (held by
another kernel object) simply gets a fresh wrapper the next time it crosses.

`GC.compact` **does move** `T_DATA` objects: measured on Ruby 3.3.6,
2000 typed-data objects declaring no `dcompact`, 406 moved in one
compaction (1999 of 2000 plain objects moved in the same run). So the
stored `VALUE` cannot be left alone. `spx_compact(payload)` runs during
the update-references phase with the old address still forwarding:
`payload->self = rb_gc_location(payload->self)` and
`((spx_obj *)payload->obj)->wrapper = payload->self`. Measured with the
same harness: 670 wrappers moved over three compactions, every wrapper's
stored `self` equal to itself afterwards, 2000 of 2000. The `GC.compact`
case in `test/ext` pins this.

**`new`.** `Cls.new` in `entries` makes `rb_define_alloc_func` +
`rb_define_method(cls, "initialize", ...)`: the shim allocates through the
kernel's constructor (`sp_Vec_new(args)` today builds and initializes in
one call), so `initialize` is the entry that takes the arguments and the
alloc function answers an uninitialized wrapper that `initialize` fills.
A class whose `initialize` cannot cross has no `new` on the host.

**Default protocol.** For every exported class the shim defines `inspect`
and `to_s` (the kernel's, through `sp_poly_inspect` / the user's `to_s`),
`==` and `eql?` (the kernel's `==`; falls back to identity), `hash` (the
kernel's `hash`, else the object pointer), `dup` and `clone` (the kernel's
copies; `clone` keeps frozen), `frozen?`/`freeze` (the kernel's header
flag). `instance_variable_get` is not provided: ivars are C fields.

**Subclassing from the host** (`class Mine < FastGeo::Vec`) is allowed as
with any C extension and has the same limits: the kernel's internal calls
are statically bound, so a host override is seen only by host callers. The
shim's `initialize` checks the wrapper's class is the mirrored one or a
host subclass of it and keeps the kernel class id the kernel's.

### Exceptions, in both directions

**Kernel → host.** `Init_k_try` answers (class name, message, object).
The shim resolves the name through the mirrored classes first
(`FastGeo::Error` is a real host class with the right ancestors), then the
host's constants for a builtin (`ArgumentError`, `Errno::ENOENT`,
`KeyError`), else `RuntimeError` with the kernel's class name prefixed to
the message so nothing is lost. For a kernel exception class that is
exported, the host object is the wrapper of the kernel exception, so
`e.message`, `e.cause` and any kernel-side readers (`e.key` for a
`KeyError` subclass) keep answering; `e.backtrace` is the host's frames.
`SystemExit` from a kernel `exit(n)` already unwinds to the try frame
(`sp_exit_raise` raises when a frame is armed); what is missing is the
status. The try helper hands the exception *object* over beside the name
and message (`sp_exc_obj[]` already holds it), the shim reads
`sp_exc_exit_status` and calls `rb_exit(n)`, which raises `SystemExit`
with that status on the host; `abort(msg)` is the same with status 1 and
the message on stderr. The kernel's own `at_exit` blocks register with
`rb_set_end_proc` at init instead of running at the end of `require`
(Part I, item 5), so they run at process exit in the order a Ruby program
expects.

**Host → kernel.** A host block, or a method on a `HostRef`, can raise or
leave non-locally (`break`, `throw`, `Thread#kill`). A longjmp across the
kernel's frames would skip its root restores and exception-stack pops, so
the callback is always run under `rb_protect`:

1. `rb_protect` returns a nonzero `state`; the shim stashes `state` and
   `rb_errinfo()` in the call's context (the `VALUE` kept in a
   `rb_gc_register_address`'d slot for the call's duration).
2. The shim raises a kernel exception of the internal class
   `Spinel::HostUnwind`, carrying only the stash index; the kernel's own
   `ensure` blocks run, a `rescue => e` does not catch it (it is not a
   `StandardError`), and it reaches `Init_k_try`.
3. Back on the host, the shim sees the class name, restores the root count
   and `rb_jump_tag(state)`: the original exception, with its original
   backtrace, or the `break` value, continues as if the kernel were a C
   function.

A kernel `rescue StandardError` therefore does not see host exceptions
in this stage; letting a kernel inspect one (`e.message`) is a later row
(a `HostRef` with `message`). This is the mirror of
`lib/sp_cext_bridge.c`'s `call_ruby_unlocked` / `sp_cext_resume_unwind`,
which carries a Spinel raise *through* extension C the other way.

### Blocks and callbacks

An entry with `&blk` or `yield` gets a `sp_Proc` the shim builds per call,
whose C body converts the yielded values with the *out* table, calls
`rb_yield_values2` under `rb_protect` (above), and converts the block's
answer with the *in* table into the type inference gave the `yield`
expression (a block whose value is unused yields `nil`). `block_given?`
answers `rb_block_given_p()` captured at entry. The proc never escapes the
call: a kernel that stores the block (`@cb = blk`) or returns it is refused,
since the host block is gone when the call returns.

A yield needs the GVL. An entry with a block is therefore always
`gvl = "hold"`; `release` on such an entry is a compile-time refusal
(re-acquiring per yield with `rb_thread_call_with_gvl` is correct but
costs two GVL transitions per element, which is the wrong default for
`each`-shaped entries).

### Threads, the GVL and the lock

**Policy per entry.** Today every call releases the GVL. Releasing costs
two GVL transitions (a mutex handoff and often a thread switch) which, for
`triple(5)`, is most of the call. The default becomes **hold**: the kernel
runs on the calling thread under the GVL like a hand-written extension, and
`gvl = "release"` is the opt-in for an entry that is long and pure
(no block, no `HostRef`). A kernel that calls `sleep` or blocking I/O under
`hold` blocks every Ruby thread, as it would in a C extension; the
differential test reports an entry that sleeps under `hold` as a warning.

**The lock stays.** The single-threaded runtime has one heap, one root
stack and one exception stack, so one call at a time per extension is a
fact, not a choice (R6). Under `hold` the lock is uncontended in the
common case (the GVL already serializes); it matters only for `release`
entries, where a second caller waits on the Ruby `Mutex` (and so releases
the GVL while waiting, as today).

**Parallel entries** are a later stage: the `_mt` runtime variant keeps
per-worker state in TLS and already *adopts* the main thread as worker 0
(`sp_sched_init`), so a calling Ruby thread could be adopted as a worker
for the duration of a `release` call and the stop-the-world collector could
park it at the entry and exit points, which are its only safepoints.
What that stage must add is the handshake between the collector and a
Ruby thread that is inside the kernel, and it changes nothing above.

**`Thread` inside a kernel is refused** in this stage, like on wasm
([wasm.md](../wasm.md)). The simple case runs today (Part I, item 7), but
the scheduler's workers, its monitor thread and its `SIGURG` handler are
process-wide state that the host, a second Spinel extension, and the
objects-by-reference stage below all have to be kept out of, and refusing
is cheaper than proving each of those. `Fiber` and external `Enumerator`s
keep working: they run on stacks the kernel maps and switch on the calling
thread only.

### The stack

An entry runs on the caller's machine stack by default. A Ruby thread's is
1 MB, so a kernel that recurses deeply, or runs at `-O0`, can overflow
there while it was fine as a program. `stack = "16M"` on an entry makes the
shim run that call on a stack the kernel maps once (the `sp_main_stack_run`
mechanism, `lib/sp_fiber.c`: an mmap with a guard page below, entered by
the fiber context switch), at the cost of one context switch per call.
The runtime's stack-guard reporter then names the overflow instead of a
bare SIGSEGV. The `_try` helper's handler-stack bound
(`sp_exc_check_depth`) is unaffected either way.

### Isolation: symbols, state, stdio

- **Visibility.** Every translation unit of the extension (the kernel, the
  shim, the vendored runtime) is compiled `-fvisibility=hidden`; the shim
  marks `Init_<feature>` `__attribute__((visibility("default")))`; the
  assembly context switch (`sp_ctx_swap`, `lib/sp_fiber_ctx.h`) gets a
  `.hidden` directive; the link adds `-Wl,-Bsymbolic` on ELF and
  `-Wl,-exported_symbol,_Init_<feature>` on Mach-O. `spin ext build`
  writes these into `extconf.rb` (`$CFLAGS << " -fvisibility=hidden"`,
  `$DLDFLAGS`), and `spin ext test` loads the extension beside a build of
  a *different* kernel and checks both answer (the probe in Part I, item
  6, is the test). Compiling only the kernel and shim hidden is not
  enough: the vendored runtime's symbols are the ones that interpose.
- **Per-feature prefix.** The kernel's non-static symbols stay `sp_*`:
  hidden visibility makes a prefix unnecessary, and the `.h` contract
  (Layer 1) keeps naming what a hand-written host links to.
- **stdio.** The shim flushes the kernel's stdio buffers (`fflush(NULL)`)
  on the way out of every entry, and the host's `$stdout` is flushed on the
  way in when it is a tty-less pipe (`rb_io_flush(rb_stdout)`); output then
  appears in program order at a cost paid only by entries that print.
- **Signals.** The ext init installs none (it already skips
  `sp_sig_install_defaults`); `trap` in a kernel is refused.
- **`ARGV`, `$0`, `ENV`.** `ARGV` is empty, `$0` is the feature name,
  `ENV` is the live environment. A kernel that reads `ARGV` compiles with a
  warning naming the read.

### The ABI, versions and packaging

- **Public API only**: the shim uses nothing outside `ruby.h`,
  `ruby/encoding.h` and `ruby/thread.h`, no `RBASIC`/`RSTRING` layout
  beyond the macros those headers export, no `rb_*` symbol the headers do
  not declare. `include/ruby.h` in this tree (the recorder's restricted
  header for the *other* direction, CRuby extensions compiled into Spinel)
  is not involved and is never on the include path of a `--ext cruby`
  build.
- **Which Ruby.** The extension is compiled by the host's `mkmf` at
  `gem install` with the host's `CFLAGS`, `-fPIC` and `DLDFLAGS`, so it
  matches that Ruby by construction. `required_ruby_version` is `>= 3.0`:
  `rb_thread_call_without_gvl`, `RB_TYPE_P`, `rb_utf8_str_new`,
  `TypedData` with `RUBY_TYPED_FREE_IMMEDIATELY` and `rb_set_end_proc`
  all predate it. A precompiled gem is one build per (platform, Ruby minor
  series): CRuby's C ABI is stable only within a minor, and `rake-compiler`'s
  `--ruby-versions` is the usual way to produce the matrix; the source gem
  remains the default `spin ext new` output.
- **Ractors.** The extension does not call `rb_ext_ractor_safe(true)`:
  the kernel is global state. CRuby then refuses to call it from a
  non-main Ractor, which is the correct answer.
- **Windows.** `mkmf` on MinGW links `-l$(LIBRUBY)` for the `rb_*` imports
  and `-Wl,-Bsymbolic` is accepted; `lib/win32/` supplies the POSIX surface
  the runtime needs ([windows.md](../windows.md)). Best effort, as the
  native Windows build is.

### Testing

`test/ext/` grows alongside each stage; every case runs under
`SPINEL_GC_STRESS=2` on the kernel side and `GC.stress = true` on the host
side at least once per suite, since the two collectors' only contract is
the pin table.

- objects: identity across calls, a wrapper dying before and after its
  kernel object, `GC.compact` with live wrappers, `Array[Vec]` in and out,
  `dup`/`==`/`inspect`, host subclass.
- exceptions: a kernel class rescued by name on the host; `exit` in a
  kernel as `SystemExit`; `break`, `raise` and `throw` from a host block
  through a kernel `ensure`; `Thread#kill` of a caller inside a `release`
  entry (today's driver has the last).
- blocks: `each`-shaped entries, a block that raises, a block that
  returns a value the kernel reads.
- isolation: two extensions in one process; the refusal messages for
  `Thread`, `trap`, an unexported class, a stored block.
- the differential (`spin ext test`): object cases spelled as
  `[:method, receiver_spec, args]`, with the pure kernel as the oracle.

### Phasing

Each stage lands behind the existing flags and leaves `make ext-cruby-test`
green; nothing in a later stage changes a decision of an earlier one.

1. **Hygiene** (fixes to what ships; no new surface): hidden visibility
   and the two-kernel test; a kernel exception class the host lacks
   re-raised as `RuntimeError` with the class name in the message, never
   `NameError`; `SystemExit` with its status and `at_exit` →
   `rb_set_end_proc`; `Thread`/`trap` refused in a kernel; `nil` into
   nullable pointer slots; stdio flush; the `gvl` attribute with `hold` as
   the default. Exit: items 4 to 7 of Part I are closed.
2. **Copy types**: `Symbol`, typed and untyped `Hash`, nested and mixed
   `Array`, `Range`, binary Strings, Bigint under `promote`. Exit: the
   crossing table's copy rows all have a driver case.
3. **Objects**: `classes`, the pin table, wrappers with identity, class
   mirroring, `new`, instance methods and attrs, the default protocol,
   kernel exception classes by name. Exit: the worked example runs from
   the host minus `each_coord`.
4. **Blocks and host unwinding**: inward blocks, `rb_protect` bridging,
   `HostRef` as an opaque pass-through. Exit: the worked example in full;
   `break`/`raise`/`throw` through a kernel `ensure`.
5. **Stacks and parallelism**: `stack =` per entry; the `_mt` adoption
   design for parallel `release` entries, as a design note first.
6. **Packaging**: precompiled gems via `rake-compiler`, the Ruby-version
   matrix in CI, `spin ext test` over both.

### Open questions

- Should `classes` default to "every class an entry's signature needs"
  rather than an explicit list? Explicit is safer for a library's API
  surface; implicit is less to write. The design keeps it explicit and
  reports what an entry would need.
- A kernel `String` crossing out copies; a kernel that returns a 100 MB
  String pays twice. `rb_str_new_static` over a frozen kernel String kept
  alive by a pin is possible, and would be the first host object whose
  bytes live in the kernel heap. Deferred until a real kernel needs it.
- Whether `hold` should auto-switch to `release` for an entry the compiler
  can prove sleeps or blocks on I/O (it already knows every `sleep` and
  blocking call site for the scheduler's sake).
