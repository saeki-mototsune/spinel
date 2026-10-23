# インクリメンタルビルド設計: 変更のないCユニットを再コンパイルしない

> 状態: 設計提案(未実装)。この文書は「編集されたファイル部分だけ C コードを
> 再生成してコンパイルを速くできないか」という問いに対する調査・検討・設計である。
> 計測は 2026-10-17、この木(`94d76988`)の `bin/spinel`、4 コア Linux、
> gcc 13.3、`-O2` で行った。

## 0. 要約

**結論: 「編集されたファイルだけ C を再生成する」のではなく、「C は毎回全体を
再生成し、変わらなかった C ユニットの `.o` を再利用する」方式を採る。**
Crystal・Nim・mypyc・Vala が実際に採っている方式で、Spinel の whole-program 型推論と
両立する唯一の安全な方式でもある(理由は §3.1)。

- 実測では、中規模までは再ビルド時間の最大の要素は C コンパイラ(`cc`)である。
  6,500 行のプログラムで全体 32 s のうち cc が 28 s、26,000 行では 79 s のうち
  cc が 44 s(4 並列)。フロントエンド(parse → analyze → codegen)は 4 s / 35 s。
  ただし 104,000 行(C 52 MB)では全体 1,022 s のうち cc は 282 s で、
  codegen 485 s + analysis 254 s のフロントエンドが 72 % を占める。フロント
  エンドは超線形(4 倍の入力で codegen 29 倍)で、大規模ではそちらが律速になる。
- 生成 C は「1 メソッド本体の編集」に対してほぼ局所的である: 26,000 行のプログラム
  の中央のメソッド 1 行を書き換えると、生成 C 167,642 行のうち差分は **2 行**。
  つまりユニット単位の内容ハッシュで `.o` をキャッシュすれば、ほぼ全ユニットが
  ヒットする。
- ただし今の生成 C には **グローバル連番**(`_tN`、`_wbN`、`_proc_N`、`_fzl_N`、
  `#line`)が埋まっており、編集位置より後ろのユニットの文字列が無意味に変わる
  (型を変える編集では 8,418 行の差分のうち 3,604 行が `_tN` の番号ずれだけ、
  `#line` ありでは 1 行の挿入で 204,844 行が変わる)。**決定性の修正が前提条件**で、
  これが設計の第 1 段階になる。
- 期待効果(試算): 26,000 行で 79 s → 約 37 s(cc がほぼ消え、フロントエンドが
  残る)。6,500 行で 32 s → 約 5 s。campfire 級(C 10 MB、cc 77 s)では cc が
  数秒になる。104,000 行では 1,022 s → 約 745 s で、残りはフロントエンド。
- その先(第 2 段階)はフロントエンドが支配的になる。入力ハッシュによる no-op
  検出と、推論結果のウォームスタートを検討する。依存グラフ付きの部分再解析
  (GHC / Zinc / Hack 型)は Crystal と同じ理由で難しく、別設計として切り出す。
  大規模プログラムでは、増分化より先に codegen の超線形性(§6.4)を直す方が
  効く。

## 1. 現状のパイプラインと計測

```
.rb ─ parse(libprism) ─ NodeTable ─ analyze(fixpoint) ─ codegen ─ 1 つの .c
      ─ [4 MB 以上なら cc -E → csplit で N 分割 → 並列 cc] ─ link ─ 実行ファイル
```

`src/main.c` が全段を 1 プロセスで回す。`codegen_program()` が `analyze_program()`
を呼び、同じ `Compiler` 構造体をそのまま読んで C を 1 本の文字列に出す
([analyze-ir.md](analyze-ir.md))。`spin build` のリビルド判定は入力の mtime
だけで([docs/spin.md](../spin.md) "Rebuilds": *There is no file-granular
incremental mode*)、何か 1 つでも変われば全段をやり直す。

既にある「部分的な」仕組み:

| 仕組み | 粒度 | 編集 1 行に対する振る舞い |
|---|---|---|
| `cc_split_build` / `src/csplit.c`(`--jobs=N`、4 MB 以上で自動) | 前処理後の C をサイズで N 等分し並列 cc | 速くはなるが全部コンパイルし直す |
| `tools/result_cache.sh`(gate の結果キャッシュ) | プログラム全体の C テキスト | 全ミス |
| `common.mk` の ccache / sccache 自動ラップ | 翻訳単位全体 | 全ミス(1 本の .c なので) |
| `spin` の native cache | パッケージの `.c` のみ | Ruby 側には効かない |
| `comp_node_ord`(`src/compiler.c`) | builtins 由来ノードの採番を builtin メソッド内で閉じる | 既に「局所採番」の前例がある |

### 1.1 フェーズ別時間(`--timing`)

`test/scale/gen.sh K` のプログラム(K ユニットの model / service / presenter 三つ組)。

| | s100(6.5k 行、C 2.0 MB) | s400(26k 行、C 9.3 MB) | s1600(104k 行、C 52 MB) |
|---|---|---|---|
| frontend(parse) | 0.05 s | 0.1 s | 0.7 s |
| analysis(fixpoint 7 ラウンド含む) | 2.7 s | 18.0 s | 253.6 s |
| codegen(analysis を除く) | 1.4 s | 16.6 s | 485.5 s |
| write_c | 0.01 s | 0.05 s | 0.2 s |
| cc(前処理 + 分割 + コンパイル + リンク) | 28.4 s(1 ユニット) | 44.2 s(4 並列; cc_compile 42.9 s) | 281.8 s(4 並列; cc_compile 275.5 s) |
| **合計** | **32.6 s** | **79.0 s** | **1,022 s** |
| cc の割合 | 87 % | 56 % | 28 % |

- s100 は 4 MB 未満なので分割されず 1 コアで 28 s。s400 は分割され 4 コアで 43 s
  (CPU 時間では約 170 s、**約 18 CPU 秒 / MB**)。
- フロントエンドは超線形: s100 → s400(4 倍)で analysis 6.7 倍、codegen
  12 倍、s400 → s1600 で analysis 14 倍、codegen **29 倍**(`tools/compile_scale.rb`
  の既知の傾向より悪い)。cc は入力にほぼ線形(C 1 MB あたり 18〜21 CPU 秒)。
  中規模までは cc が、大規模では codegen が律速で、本設計(cc の増分化)が
  効く範囲はその境目(数万行)までになる。超線形性そのものは本設計の対象外だが、
  第 2 段階の動機になる(§6.4)。
- `--jobs=16` を 4 コア機で試すと cc_compile は 51 s に悪化する。並列度は
  コア数まで。

### 1.2 翻訳単位 1 つあたりの固定費

ユニットを細かくすればするほど、各ユニットが `#include "spinel_rt.h"`
(21,336 行、`static inline` だらけ)を読む固定費を払う。

| | 時間 |
|---|---|
| ヘッダだけの TU、`-O2` | 0.60 s |
| 同、`-O0` | 1.9 s(`-O0` は未使用の static 関数も落とさずに生成するため遅い) |
| 同、`-O2`、gcc の PCH(`.gch`) | 0.54 s |

→ ユニットは「1 メソッド = 1 TU」にはできない(s400 は 8,813 関数定義: 固定費だけで
88 分)。**ユニットあたり 200〜400 KB の C**(本体コンパイル 4〜7 s)にまとめて
固定費を 10〜15 % に抑える。PCH の効きは小さい(gcc で 10 %)。

### 1.3 1 行の編集が生成 C をどれだけ変えるか

s400 の中央(`Model200`、12,600 行目付近)を 1 行書き換え、`-c --no-line-map`
の C を `diff` した。

| 編集 | 差分行数 / 167,642 | うち `_tN` 番号ずれのみ |
|---|---|---|
| a. 到達可能メソッド本体の文字列を変更(`def label`) | **2** | 2 |
| b. 戻り値の定数を変更(`def weight = 2` → `= 3`) | **2** | 0 |
| c. 戻り値の型を変更(`= 2` → `= 2.5`、Integer → Float) | **8,418** | 3,604 |
| d. a に加えて行を 1 つ挿入、`#line` あり(デフォルト) | **204,846** | (うち `#line` 行 204,844) |

読み取れること:

- 型を変えない編集は、そのメソッドの関数本体にしか現れない(a, b)。これが
  本設計が成り立つ根拠。
- 型を変える編集は whole-program 推論を通じて広がる(c: `Model200#weight` が
  Float になり、`Model200#score` が boxed になり、呼び出し側のシグネチャと
  dispatch が変わる)。**この広がりは正しく、必要な再コンパイル**である。だが
  差分の 43 % は後続メソッドの `_tN` が 1 ずつずれただけの無意味な差分で、
  これを消せば c の実際の差分はおそらく数百行に収まる。
- `#line` はデフォルトで有効で、1 行の挿入が同じファイルの後続すべての
  `#line` を変える(d)。ハッシュから除外しなければ事実上キャッシュが効かない。

生成 C に埋まっているグローバル連番(s400 で確認したもの):

| 名前 | 何の番号か | 最大値(s400) |
|---|---|---|
| `_tN` | 式の一時変数(`g_tmp`、`codegen_util.c`) | 29,535 |
| `_wbN` | 書き込みバリアの一時変数 | 35,208 |
| `_proc_N` / `_proc_cap_scan_N` | ブロック・ラムダの関数名(`g_proc_counter`) | — |
| `_fib_cap_N` | Fiber のキャプチャ構造体 | — |
| `_fzl_N` | frozen 文字列リテラル(出現順、408 個) | 408 |
| `__fwdc_N`、`x__bpN` 等 | `comp_node_ord` が付ける番号(プログラム側はテーブル順) | — |
| `case 2:` / `(sp_Class){N}` | クラス id(登録順) | — |
| `(sp_sym)N` | シンボル id(intern 順; codegen の 59 箇所が数値で書く) | — |

上 5 行はユニット内に閉じられる(§4.3)。クラス id・シンボル id は本質的に
プログラム全体の番号なので、クラスやシンボルを **追加** する編集は、それを使う
ユニットの正当なミスになる(Crystal の type-ID 問題と同じ。§2.1)。末尾に追加
される限り既存の番号は動かない。

## 2. 他のコンパイル言語の調査

一次資料(各コンパイラのソース・公式ドキュメント)に当たった要点。Spinel への
含意を各項末尾に書く。

### 2.1 Crystal: Spinel に最も近い(whole-program 型推論、Ruby 風)

- 型ごとに 1 つの LLVM モジュール(`CompilationUnit`)を作り、`~/.cache/crystal/`
  に `<型名>.bc` と `.o` を置く。再利用判定はハッシュではなく **bitcode の
  バイト比較**(`must_compile?` が新しい bitcode をメモリに生成し `IO.same_content?`
  で前回の `.bc` と比べる)。一致すれば `.o` をそのまま使う。
  `--release` は `--single-module`(1 モジュール、最適化優先)を含意する。
  (`src/compiler/crystal/compiler.cr`)
- 意味解析(型推論)は毎回全体をやり直す。「コンパイラは毎回プログラム全体を
  最初からコンパイルする」(Ary Borenszweig, *Incremental compilation for
  Crystal* part 1/2)。呼び出し側から引数型を推論するため、1 箇所の型変更が
  プログラム全体に波及し得る、というのが本質的な理由。
- キャッシュが効かない代表例: 型 ID が出現順の連番で IR に定数として埋め込まれる
  ため、ファイル先頭に無関係なクラスを足すと後続すべての型の ID がずれ、
  全モジュールの bitcode が変わる(forum "Incremental compilation
  exploration")。
- 時間の内訳は開発ビルドでは型検査が主、リリースでは LLVM の最適化が主。

**含意**: 方式はそのまま使える。失敗例(連番 ID の漏れ)は Spinel にも §1.3 の
表の通り存在し、避けるべき点が明確。

### 2.2 Nim: C を出すコンパイラの標準的な答え

- Nim モジュールごとに 1 つの `.c` を `nimcache` に書く。`shouldRecompile` が
  生成した C 文字列を既存ファイルと比較し(`equalsFile`)、同じなら書き直さず、
  `.o` が新しければ `CfileFlag.Cached` を立てて **C コンパイラを呼ばない**
  (`compiler/cgen.nim`, `extccomp.nim`)。
- 外部 C ファイルは内容の SHA-1 + OS + CPU + コンパイル行の footprint を
  `.sha1` サイドカーに持つ。
- `<project>.json` にコンパイル行と全 Nim ソースのハッシュを書き、何も変わって
  いなければコンパイル全体を省略する(no-op 検出)。
- フロントエンド側の IC(`.rod` パック AST、`--incremental:on`)は長年
  experimental のまま、現在の `devel` からは機構が外れており、後継の Nim 3
  (Nimony)で NIF 中間ファイルとして設計し直している。**C を出すコンパイラで
  実用になったのはバックエンド側のキャッシュだけ**、という事実が重要。

### 2.3 Rust (rustc): 問い合わせシステムと codegen unit

- 全計算を query にし、query 間の依存 DAG と結果の 128 bit フィンガープリントを
  セッション間で保存する。次回は red-green アルゴリズムで、依存が全部 green なら
  実行せずに結果を再利用、red なら再実行して結果が同じなら green に戻す
  (変更の伝播を結果の同一性で止める)。
- LLVM は query ではないので **codegen unit(CGU)** 単位で扱う: CGU の IR を
  作るのに読んだ query を記録し、全部 green なら前回の `.o` をコピー。分割規則は
  「ソースのモジュールごとに 2 つ(非ジェネリックの安定部分 / 単相化された揮発部分)」
  → 目標数まで併合。incremental では CGU 名をモジュール名から安定に導出する。
- トレードオフを明文化: incremental ビルドは CGU 256(細かく)、release は
  CGU 16 かつ incremental off(「最適化を阻害するので release には勧めない」)。
  LLVM はモジュール境界を越えて最適化できない。

**含意**: 「開発ビルドは細かいユニット、リリースは 1 ユニット」の二本立て。
ユニット名はソース上の意味単位から安定に導く。

### 2.4 GHC: インタフェースのハッシュで伝播を止める

- `.hi` にモジュールの ABI ハッシュ・エクスポートハッシュ・宣言ごとのハッシュを
  持ち、各モジュールは「使った宣言のハッシュ」を記録する。使った宣言が全部
  同じなら再コンパイルしない(`GHC/Iface/Recomp.hs`)。
- **本体の変更と型の変更の伝播が違う**: 関数本体は、その unfolding がインタフェース
  に出る(`-O` で小さい関数)場合にだけ宣言ハッシュに入る。`-O0` では本体だけの
  編集は呼び出し側を再コンパイルさせない。

**含意**: ユニットのキーには「そのユニットが使うものの宣言」だけを入れれば、
無関係なメソッドの追加でミスしなくなる(§4.4 の v2)。inline 対象の短いメソッド
は GHC の unfolding と同じ扱い(使う側に本体が入る)。

### 2.5 Go: パッケージ単位のコンテンツアドレスキャッシュ

- アクション ID = 入力(コンパイラバイナリ、フラグ、全ソース内容、依存の
  **export data** の内容 ID)のハッシュ。依存パッケージの本体だけの変更は
  export data を変えないので、依存先の再コンパイルを起こさない。
- キャッシュは `$GOCACHE` にコンテンツアドレスで置かれ、プロジェクト間で共有、
  使われないエントリは期限で捨てる。`go build -x` でヒットを確認できる。

**含意**: キーの組み立て方(コンパイラ自身の同一性・フラグ・ランタイムヘッダを
必ず含める)と、ユーザーキャッシュディレクトリでの共有・prune の運用。
`tools/result_cache.sh` の `fp` が既に同じ考え方。

### 2.6 Swift: 宣言粒度の依存グラフと batch mode

- `.swiftdeps` に各ファイルの provides / depends(トップレベル名・型・メンバ)を
  書き、ドライバが変更ファイルと依存ファイルだけを再コンパイルし、再コンパイル後
  に新しい依存を読み直して第 2 波を回す。
- batch mode は 1 フロントエンドに複数ファイル(既定 25 個まで)を担当させ、
  プロセスあたりの固定費を割る。

**含意**: 固定費(§1.2)を割るためのユニットまとめ方(§4.3)。

### 2.7 Zig: その場でバイナリを書き換える

- 宣言単位で解析状態を保存し、自前リンカが出力 ELF をその場で更新する。
  2026 年時点で `-fincremental` は実験的、x86_64 Linux Debug 向け、release には
  効果が薄い。

**含意**: 到達点として興味深いが、cc をバックエンドに使う Spinel には適用不可。

### 2.8 ccache / sccache と ninja の depfile

- ccache の direct mode は「ソース + オプション + 読んだヘッダの内容」で
  manifest を引き、preprocessor mode は `-E` 出力のハッシュで引く。
- ninja は `restat = 1` で「コマンドが出力を書き換えなかった(mtime 不変)」を
  検出して下流を刈る。Nim / mypyc のように「内容が同じなら `.c` を書き直さない」
  ジェネレータはこれと組み合わせて C コンパイルが省かれる。

**含意**: 汎用ツールで代替できるのは「分割後のユニットの C コンパイル」だけで、
Spinel 側の分割と決定性は自前で要る。ccache を使う構成(`common.mk` の自動
ラップ)はユニット分割後にそのまま乗る。

### 2.9 Unity / jumbo build(C++)

- Chromium の jumbo は 50 ファイルを 1 TU にまとめて総 CPU を減らしたが、
  「1 ファイルの変更で大きな TU を丸ごと再コンパイルするため単一ファイルの
  再コンパイルが遅くなる」(10〜20 s の罰)。後に廃止。

**含意**: ユニットサイズの上限は「ミス 1 つの再コンパイル時間」で決める。
200〜400 KB(4〜7 s)が目安。

### 2.10 mypyc / Vala / Nuitka / CHICKEN

- mypyc: `write_file` が内容が同じならファイルを書かず mtime を保つ
  (「再コンパイルを起こさないため」)。
- Vala: `.vala` ごとに `.c` を出し、変わらない `.c` は書き直さないが、
  **全 `.vala` を毎回解析する**(全シンボルが要るから)。定数のインライン化で
  `a.vala` の編集が `b.c` を変える、という Spinel と同じ現象がメーリングリストで
  説明されている。
- Nuitka: モジュールごとに `.c`、ccache 任せ。「プログラムの変更で多くの C
  ファイルが変わり得る」と公式に注意書き。

### 2.11 whole-program 解析のインクリメンタル化(研究・LSP)

- Salsa(rust-analyzer)/ Adapton: メモ化 + 依存追跡 + backdating(再実行して
  同じ値なら下流を無効化しない)。
- Zinc(Scala): API ハッシュ + 使用名のハッシュ(name hashing)で無効化集合を
  絞る。「推論された戻り値型が本体の変更を API に漏らす」が既知の落とし穴
  — Spinel はこの漏れが常態。
- Hack / Pyrefly / Sorbet: 依存グラフを永続化し fanout を再検査。Sorbet は
  「メソッド本体だけの変更」を per-file ハッシュで検出した時だけ fast path。
- 学術: co-contextual typing(Erdweg 2015)、scope-graph 由来の incremental
  type checking(Zwaan 2022)。

**含意**: 第 2 段階以降の設計の出発点。Spinel の推論は呼び出し側から引数型を
決めるので、Sorbet 型の「本体だけの変更なら局所」という単純化が成り立たない
(Crystal と同じ)。§6.3。

### 2.12 横断的な教訓

1. C / LLVM を出すコンパイラの実用的な高速化は例外なく **バックエンド側の
   内容比較**(Nim、Crystal、mypyc、Vala、Nuitka)。
2. whole-program 推論を持つものはフロントエンドを毎回回す。効くのは
   (a) 入力ハッシュによる no-op 検出、(b) 出力ユニットを安定させてバックエンド
   キャッシュを当てること。(b) を壊す最大の敵は **連番 ID の漏れ**。
3. 本当のフロントエンド増分化には宣言ごとのインタフェースハッシュと依存追跡が
   要り、どれも「推論された型が本体の変更を漏らす」カスケードを抱える。

## 3. Spinel 固有の制約

### 3.1 「編集されたファイルだけ再生成」はなぜ直接はできないか

`require` / `require_relative` はパーサが **テキストとして 1 つのバッファに
スプライス**し(`src/spinel_parse.c`)、解析は 1 つの `NodeTable` に対して
whole-program で走る。ある `.rb` のメソッドの C は、

- そのメソッドの本体、
- 呼び出し側全部から推論された引数の型(`infer_param_types`)、
- 呼び出す先の戻り値型・ivar 型・クラス構造(value type 化、nullable、poly 化)、
- dispatch テーブル(`sp_pd_*`)、クラス id、シンボル id、

の関数であり、後ろ 3 つは他のファイルの編集で変わる(§1.3 の c)。ファイル単位
で「このファイルは変わっていないから C も前回のまま」と判断すると、Vala の
`#define x 4` 問題と同じく **黙って古い型の C をリンクする**ことになる。
Spinel の約束(CRuby と同じ答えか refusal)を守るには、正しい C は毎回全体から
作り、「同じかどうか」を **生成結果の側**で判定するしかない。

これは諦めではない。codegen は s400 で 16.6 s、cc は 170 CPU 秒であり、
「全体を再生成して差分だけ cc」でも cc の大半が消える。「ファイル単位で
C 生成を省く」(フロントエンドの増分化)は、その後に残る 35 s を削る第 2 段階の
問題として分離する(§6)。

### 3.2 既存の csplit との関係

`cc_split_build` は **前処理後**(`cc -E`、s400 で 0.75 s)のテキストを
`csplit.c` が C として読み、関数をサイズで N 等分する。目的は並列化であって
安定性ではない:

- 分割境界はサイズで決まる → 1 メソッドの編集で境界が全部ずれる。
- 前処理後なのでシステムヘッダの展開を含み、ハッシュの安定性が悪い。
- 共有ヘッダ `sp_split.h` が大きい(s100 で 1.36 MB: 全プロトタイプと
  `static inline` 本体)。これを全ユニットが読む固定費も、§4.4 の v2 で
  ユニットごとの import list にすると消える。
- 前処理の 0.75 s と分割の 0.2 s は余計なコスト。

本設計は csplit の「ヘッダ(型・プロトタイプ・extern・`static inline`)と
本体(`static` を外した関数)への分離」という成果物の形を引き継ぎつつ、分割を
**codegen が直接**、意味単位のキーで行うものに置き換える。`EMIT_COLLECT_UNIT`
(`codegen.c`)がメソッド単位の出力境界を既に持っており、そこが接ぎ木点になる。

### 3.3 決定性

`tools/cident.sh` が「生成 C がバイト同一」を保証しているのは *同じ入力* に対して
であり、*近い入力* に対する安定性(編集の局所性)は今まで要求されていなかった。
§1.3 の連番はすべてこの観点で直す必要がある。前例として `comp_node_ord` が
builtins のノード番号を「所属する builtin メソッドの中で」付ける仕組みを既に
持っている(「builtin が増減しても自分の名前しか動かない」)。同じ考え方を
プログラム側のノードにも広げる。

## 4. 設計

### 4.1 目標と非目標

目標:

- 編集 → 再ビルドの時間を「フロントエンド + 変わったユニットの cc + リンク」に
  する。型を変えない編集なら cc はユニット 1〜2 個。
- 出力バイナリは from-scratch ビルドと **同一**(ユニットの `.o` が同じ内容から
  できているので、リンク順を固定すれば同一になる)。gate で検証可能。
- 既存の `--jobs` の並列化を包含する(ミスしたユニットを並列 cc)。
- `spinel` 単体でも `spin` 経由でも使える。キャッシュはプロジェクト間で共有可能。

非目標(この設計では扱わない):

- フロントエンドの部分再解析(§6 で方向だけ示す)。
- 最適化の品質を保ったままの増分化。リリースビルドは現状の単一ユニットのまま。
- wasm32-wasi(現状も分割しない)。

### 4.2 全体像

```
.rb ─ parse ─ analyze ─ codegen ──┬─ sp_program.h   (型, ランタイム include, 共有宣言)
                                   ├─ unit_<key>.c  × N  (本体; 安定キー順)
                                   └─ unit_program.c      (main, sp_tu_init, dispatch, グローバル定義)
                                         │
                            ユニットごとに  key = H(format, spinel-rev, cc-id+flags,
                                                   H(lib/*.h), H(sp_program.h), H(正規化した本体))
                                         │
                   ┌─ hit  ─ $CACHE/objects/<key>.o をそのまま使う
                   └─ miss ─ cc -c unit_<key>.c(並列、コア数まで)→ .o をキャッシュに入れる
                                         │
                                      link(全 .o をキー順) ─ 実行ファイル
                                         │
                           バイナリキャッシュ: H(全ユニット key + リンク行) → リンクも省略
```

### 4.3 ユニットの切り方

**キー(安定名)**: メソッドには `<file>:<Class>#<method>`(`emit_method_cname`
の C 名で十分: `sp_Model200_label`)、クラスの構築子・`sp_<Class>__gc_scan` 等は
`<Class>`、builtins 由来は `builtins/<file>:<method>`。キーは **ソース上の
意味**から来るので、他の場所の編集で動かない。

**まとめ方(bin packing)**: キーをソース順(ファイル → クラス → メソッド)に
並べ、意味的境界で区切る:

1. ファイルごと、その中でクラスごとにグループを作る。
2. グループが上限(既定 300 KB、`--unit-bytes=` で変更)を超えたらメソッド順で
   分割する。小さいグループは隣接するものと **同じファイル内で** 併合する。
3. builtins のメソッド(`enumerable.rb` 等。s400 では `#line` の 5 %)は
   プログラムとは別のユニット列にする。ほとんど変わらない。
4. `unit_program.c`: `main`、`sp_tu_init`、dispatch 関数(`sp_pd_*`、inspect /
   to_h / marshal の dispatch)、クラス機構(`sp_cls_*`)、グローバル変数・定数・
   frozen リテラルの **定義**。これはクラスやメソッドの追加で変わるが 1 つだけ。

境界を「ファイル / クラス」にするのは、1 メソッドのサイズ変化で隣のユニットの
境界が動かないようにするため(csplit のサイズ等分では動く)。Rust の
「モジュールごとに CGU、その後併合」、Chromium jumbo の「チャンク 50」の
中間。ユニット数は概ね 20〜100。

**ユニットに同居するもの**: メソッドが含むブロック・ラムダの関数(`_proc_*`)、
Fiber のキャプチャ構造体、そのメソッド専用の `static` ヘルパ。今は
`g_procs` / `g_proc_protos` という別バッファに集めて本体の前に差し込んでいるが、
ユニット化ではメソッドの直前に置く。

### 4.4 共有ヘッダと「ユニットが使う宣言」

ユニットのキーに入るのは `sp_program.h` のハッシュ全体なので、**ヘッダが変わると
全ミス**になる。何がヘッダに入るかがヒット率を決める。2 段階で進める。

**v1(Crystal 相当)**: csplit と同じ構成。型(クラス構造体、typedef)、
全メソッドのプロトタイプ、グローバルの `extern`、`static inline` 関数すべてを
1 つのヘッダに置く。

- 効く編集: メソッド本体の変更(型不変)、定数値の変更。
- 全ミスする編集: メソッドの追加・削除・シグネチャ変更、ivar 追加、クラス追加、
  frozen リテラルの追加(`_fzl_` の `extern` が増える)、短い(`static inline`
  扱いの)メソッドの本体変更。

これは「毎回 `--jobs` で全部コンパイル」より悪くならないが、「メソッドを
1 つ足す」という最も普通の編集で効かないので v1 止まりにはしない。

**v2(GHC / Go 相当、本設計の到達点)**: 共有ヘッダには **型とランタイム include
だけ**を置き、各ユニットの先頭に **そのユニットが参照するものの宣言**
(プロトタイプ、`extern`、`static inline` 本体)を codegen が書く。ユニットの
テキスト = 本体 + 自分の import list なので、

- メソッド追加: 新メソッドのユニットと `unit_program.c`(dispatch に入るなら)
  だけが変わる。
- シグネチャ変更: そのメソッドと **呼び出し側のユニット**だけが変わる(正しい
  再コンパイル集合)。
- 短い inline メソッドの本体変更: その本体を import したユニットだけ
  (GHC の unfolding と同じ)。
- リテラル追加: 定義側(`unit_program.c`)と使う側だけ。
- ivar 追加 / クラス追加: 型ヘッダが変わる → 全ミス。v2 でも残る。型ヘッダを
  クラスごとのブロックに分け、ユニットが触るクラスの型ブロックだけを import する
  v3 は可能だが、構造体の相互参照(ポインタは前方宣言で足りる)の整理が要るので
  ここでは範囲外とする。

参照集合の求め方: codegen が出力時に記録するのが理想だが、呼び出しの経路は多い
(`codegen_call*.c` 30 万行)。現実的には **ユニット本体のテキストを識別子で
走査し、宣言テーブル(メソッド C 名、グローバル名、リテラル名、inline 関数名)
との共通部分を取る**。csplit が既に C を字句的に読んでおり、同じ字句読みで
識別子集合は取れる。コストは線形で、s400 の 9 MB でも 0.1 s 級。

### 4.5 決定性の修正(前提条件)

| 対象 | 変更 |
|---|---|
| `g_tmp`(`_tN`)、`_wbN`、その他の式一時変数カウンタ | 各トップレベル関数(メソッド、proc、dispatch)の出力開始で 0 にリセット。関数内のみで使われる名前なので衝突しない。`codegen.c:604` 等の save/restore はそのまま動く |
| `g_proc_counter`(`_proc_N`、`_proc_cap_scan_N`、`_capv_N`) | 関数名なので TU 内で一意が要る。`_proc_<所属メソッドのC名>_<n>` とし、`n` はメソッド内の連番。トップレベル(main)の proc は `_proc_main_<n>` |
| `_fib_cap_N` | 同上 |
| `_fzl_N`(frozen リテラル) | 内容のハッシュ名 `_fzl_<8桁hex>`。同内容のリテラルは今も 1 つに共有されている(s400 の 408 個は内容で重複なし)ので、変わるのは名前だけ。衝突は codegen がテーブルで検出し、`_fzl_<hex>_2` で避ける |
| `comp_node_ord`(`__fwdc_N`、`x__bpN`) | base を「builtins のメソッド」から「すべてのメソッド / クラス本体 / トップレベル文」に広げる。既存の `comp_node_base` が `nscope[k]` → `scopes[si].def_node` を見る経路を持っているので、`node_bi` を持たないノードにも同じ規則を適用する。名前は `comp_node_tag` と同じ `q<base>_<n>` 形 |
| `#line` | 出力ファイルには今まで通り書く(診断・gdb のため)。**ハッシュは `#line` 行の行番号を落として計算**する(`-g` / `--debug` でないとき)。生成 C は `__LINE__` を使わない(s400 で 0 件)ので、行番号は `-g` なしの `.o` に入らない。`-g` のときは `#line` を含めてハッシュ(行シフトでミスするが、`-O0` なので cc は速い) |
| クラス id、シンボル id | 変更しない。追加は末尾番号なので既存は動かない。`(sp_sym)N` と数値で書く 59 箇所は、名前付きの定数(`SPS_<name>` 系)に寄せられるなら寄せる(読みやすさの改善でもある) |

これらは **既存の出力の意味を変えない**(名前の付け替えだけ)ので、`make test`
と `tools/cident.sh` 相当の検査で回帰を見られる。

新しい検査 **`tools/unit_stability.sh`**: §1.3 の実験を自動化する。s400 相当の
プログラムに (a)〜(c) の編集を加え、変わったユニット数(と差分行数)が上限
(a, b: 1 ユニット; c: 呼び出し関係の範囲)以内であることを gate の 1 脚にする。
scale-test が「仕事量の線形性」を守っているのと同じ役割を「編集の局所性」について
担う。

### 4.6 キャッシュ

**キー**(SHA-256、`tools/result_cache.sh fp` と同じ材料をそろえる):

```
format-version
spinel のリビジョン(`spinel --version` の括弧内; 同じリビジョンなら同じ C を出す前提)
cc の identity(`cc --version`, `-dumpmachine`)とユニットのコンパイル行(-O, -D, -I, -ffunction-sections …)
H(lib/*.h, lib/spinel/*.h, platform headers)   … ランタイム API
H(sp_program.h)                                … 型
H(正規化したユニット本文)                      … 本体 + import list(v2)
```

**配置**: `$XDG_CACHE_HOME/spinel/objects/<k0k1>/<key>.o`(`spin` の native
cache `$XDG_CACHE_HOME/spin/native/` と同じ流儀)。`SPINEL_CACHE_DIR` で変更、
`SPINEL_NO_CACHE=1` で無効。書き込みは一時名 → `rename`(同時ビルドの安全性は
result_cache.sh の `claim`/`release` と同じ)。prune は最終アクセスから 14 日。

**バイナリキャッシュ**: 全ユニットの key 列 + リンク行 + ランタイムアーカイブの
ハッシュ → 出力バイナリ。何も変わっていなければリンクも省く(`spin test` が
同じ入力を続けて何度もビルドする場面向け)。

**ヒット時の `.o`**: 古いビルドで作られた `.o` を使うので、`#line` の行番号は
古い(§4.5)。`-g` なしではバイナリに影響しないが、cc の警告・エラーが出るのは
ミス(= 実際にコンパイルする)ユニットだけなので診断は常に新しい行番号で出る。

### 4.7 コンパイルとリンク

- ミスしたユニットを `fork`/`exec` で並列 cc(現 `cc_split_build` のループを
  流用; 並列度はコア数まで、`--jobs` で上書き)。
- `.o` は `-ffunction-sections -fdata-sections` のまま、リンクは
  `--gc-sections` のまま。ユニット化で `static` を外す関数が増えるが、死んだ
  関数は section ごと落ちるので現状と同じ(csplit がもう同じことをしている)。
- リンク順はユニットキー順で固定(バイナリ同一性のため)。
- cc が失敗したら、ミスしたユニットの `.c` と `sp_program.h` を残して場所を言う
  (現状の "the generated C is kept at" と同じ)。
- インライン化: 現状「4 MB 未満は単一ユニット(optcarrot で 10 % の差)」の
  方針は **リリースビルドでは維持**する。`--incremental` はユニット分割を伴うので
  開発ビルド向け。`spin build`/`run`/`test` は `--incremental`、
  `spin build --release`(新設、または `spin pack`)は現状の単一ユニット。
  Rust の dev / release と同じ線引き。

### 4.8 CLI と spin

- `spinel --incremental[=DIR] prog.rb`: ユニット分割 + キャッシュ。
  `--unit-bytes=N`、`--cache-stats`(hit / miss / ユニット数を stderr に)。
  `--timing` に `cache_lookup`、`cc_compile units=N miss=M` を足す。
- `spinel -c --incremental` は `prog/` ディレクトリに `sp_program.h` と
  `unit_*.c` を書く(デバッグ・外部ビルド用。`spin pack` の Makefile 生成も
  これを使える)。
- `spin build/run/test`: mtime 判定で「変わった」と判断したら `--incremental`
  付きで spinel を呼ぶ。`spin clean --cache` はオブジェクトキャッシュも消す。
- `common.mk` の ccache 自動ラップはユニット単位の cc に対してもそのまま効く
  (ユニットの `.c` が同じなら ccache も当たる)。ただし自前キャッシュがある以上
  二重になるので、`--incremental` 時は `CC` のラップを外すか、ccache を
  バックエンドとして使う(自前の `.o` 保存を省く)かを実装時に測って選ぶ。

### 4.9 期待効果(試算)

| | 現状 | 型を変えない 1 メソッド編集後 | 内訳 |
|---|---|---|---|
| s100(6.5k 行) | 32.6 s | **約 5 s** | frontend 4.2 + cc 1 ユニット ≈ 0.6+0.3 + link 0.1 |
| s400(26k 行) | 79 s | **約 37 s** | frontend 35 + cc 1 ユニット ≈ 1.5 + link 0.3 |
| campfire 級(C 10 MB、cc 77 s) | 77 s + frontend | **frontend + 数秒** | |
| s1600(104k 行) | 1,022 s | **約 745 s** | frontend 740 + cc 1 ユニット ≈ 2 + link 1.3 |

- 型を変える編集(§1.3 c)は、呼び出し関係の範囲のユニットがミスする。s400 の
  例では `Model200` と `Service200` を含むユニット 1〜2 個 + `unit_program.c`。
- 何も変えずに再ビルド: バイナリキャッシュで frontend すら走らない(§4.6)。
- 第 1 段階の後は **フロントエンドが支配的**になる(s400 で 37 s のうち 94 %)。
  s1600 では第 1 段階の効果は 27 % にとどまり、codegen の 485 s が残る。§6 の動機。

## 5. 実装計画

PR 単位。1〜3 は `make gate` と `tools/cident.sh` で回帰を見る(出力の意味は
変わらない)。

1. **決定性**(§4.5)。カウンタのリセット、`_proc_`/`_fzl_`/node_ord の命名、
   `tools/unit_stability.sh` と gate の脚。この PR 単独でも ccache / sccache の
   ヒット率と `result_cache.sh` の意味が改善する(前処理後の等分ではなく)。
   触る場所: `codegen_util.c`(`g_tmp`)、`codegen.c`(`g_proc_counter`、
   `_fzl_`、`EMIT_COLLECT_UNIT` 周辺)、`compiler.c`(`comp_node_base`)。
2. **ユニット出力**: `codegen_program` が `Buf` 1 本ではなく「ユニット列 +
   ヘッダ」を返す構造(`CodegenOutput { header; units[]; program_unit }`)。
   `-c --incremental` でディレクトリに書く。`main.c` の `cc_split_build` を
   ユニット列を受ける形に置き換え、csplit は(前処理を経ない)フォールバック
   として残すか削る。`--jobs=N` は「ユニットを N 個まで併合して並列 cc」の
   意味に再定義し、出力バイナリが現状と同じ(`make test`、optcarrot checksum
   59662)であることを確認。
3. **import list(v2)**: ユニット本文の識別子走査 → 宣言テーブルとの共通部分を
   ユニット先頭に書く。`sp_program.h` から宣言が消え、型だけになる。
4. **オブジェクトキャッシュ**: キー、lookup、並列 cc、prune、バイナリキャッシュ、
   `--cache-stats`、`--timing` 項目。`make incremental-test`: from-scratch と
   incremental(編集 a〜c を挟む)の出力バイナリが同一、ミス数が上限内。
5. **spin 連携とドキュメント**: `spin build --release`、`spin clean --cache`、
   `docs/spin.md` "Rebuilds" の書き換え、`README.md` のアーキテクチャ図。
6. **計測ツール** `tools/incremental_bench.sh`: 代表プログラムに編集を加えて
   「編集 → 再ビルド」の壁時計時間を出す(`compile_scale.rb` の増分版)。

## 6. 第 2 段階: フロントエンドを短くする

第 1 段階後に残るのは analyze + codegen。方向と判断を記す。

### 6.1 no-op 検出(やる)

全入力(スプライス後のソース、`-I` で解決したファイル、RBS、フラグ、spinel
リビジョン)のハッシュ → 前回の出力バイナリ。Nim の JSON build / Go の action ID。
`spin` の mtime 判定より厳密で、`spinel` 単体でも効く。§4.6 のバイナリキャッシュ
の手前にもう 1 段置くだけ。

### 6.2 推論のウォームスタート(測ってから決める)

前回の推論結果(param / return / ivar 型の表)を seed にして fixpoint を始める
(`--rbs` の seed 機構が既に「スロットを固定する」入口を持つ)。ラウンド数が
7 → 2 になれば analysis は線形に縮む。

ただし [fixpoint-convergence.md](fixpoint-convergence.md) にある通り Spinel の
fixpoint は **単調ではない**(narrow のためにスロットを毎ラウンド UNKNOWN に
戻す)。seed から始めた固定点が from-scratch の固定点と一致する保証がないと、
「同じプログラムが前回と違う型付けになる」= 再現性の喪失になる。採るなら
**seed はヒントとしてだけ**使い(固定しない)、最終的に from-scratch と同じ
C が出ることを `tools/cident.sh` で全コーパスについて示す、という条件付き。

### 6.3 依存グラフ付きの部分再解析(別設計)

GHC / Zinc / Hack の方式をそのまま持ち込むには、メソッドごとに「使った名前」と
「インタフェース(推論された param / return 型)」を記録し、インタフェースが
変わらなければ依存先を再解析しない、という不変条件が要る。Spinel では引数型が
呼び出し側から来るため、本体の編集 → 呼び出しの引数型の変化 → 被呼び出し側の
param 型の変化 → その戻り値型 … と、Zinc が「推論された戻り値型が API に漏れる」
と呼ぶ経路が主経路になる。Crystal が 10 年来取り組んで実装に至っていないのも
同じ理由。

現実的な入口は Sorbet の fast path に相当する **「編集がメソッド本体に閉じ、
かつ本体を再推論してもそのメソッドのシグネチャ(param / ret / 触る ivar の型)
が変わらない」場合だけ、他のメソッドの再推論を省く**という限定形。判定自体に
そのメソッドの再推論が要るので、実装は「全体の fixpoint を回す代わりに、
変更メソッドを含むスコープだけ再推論 → シグネチャ比較 → 不一致なら全体へ
フォールバック」。これは解析器の内部(スコープ単位で passes を回せるか)に
踏み込むので、第 1 段階の計測結果を見てから別文書で設計する。

### 6.4 analysis の超線形性

s100 → s400 で analysis 6.7 倍、codegen 12 倍、s400 → s1600 で analysis 14 倍、
codegen 29 倍(§1.1)。codegen は s1600 で 485 s と単独最大のフェーズになり、
入力の 2 乗より悪く伸びている(`make scale-test` は `spinel-work` の名前比較
回数を見張っているが、codegen の壁時計はこの比率で伸びている)。これは
増分化とは独立の性能課題で、大規模プログラムでは本設計より先に効く。
`--timing` の pass 別出力(s400 では `infer_write_types`、
`narrow_object_arrays`、`promote_shared_stored_strings`、`infer_block_params`
が上位)と、codegen 側の `--timing` を細分化したプロファイルから取り組む
価値がある。

## 7. リスクと未解決事項

- **型ヘッダの変更で全ミス**(ivar / クラスの追加)。v3(クラスごとの型ブロック
  を import)で縮められるが、構造体の依存整理が要る。まず v2 で実測してから。
- **inline 短メソッド**: ヘッダ(v1)/ import(v2)に本体が入る。変更時の
  ミス範囲は呼び出し側全部。許容範囲だが、`--incremental` では inline 化を
  やめる選択肢もある(開発ビルドの実行速度を少し落とす)。
- **ccache との二重化**: §4.8。測って一方に寄せる。
- **キャッシュ容量**: `.o` の合計は s100 で 6.4 MB(4 ユニット、バイナリは
  2.0 MB)、s400 では 25 MB 程度 / ビルド。編集ごとにミス分だけ増える。
  14 日 prune で十分。
- **Windows / wasm**: wasm は現状どおり分割しない。Windows は `fork` を使う
  並列 cc を `win32.mk` 側の流儀に合わせる(現 `cc_split_build` と同じ制約)。
- **`--ext`(CRuby 拡張出力)、`--emit-*`**: 単一ファイル出力のまま。
  `--incremental` と排他。
- **診断の行番号**: ヒットした `.o` の `#line` は古いが、`-g` なしでは
  バイナリに入らない。`--debug` は `#line` をハッシュに含める。

## 付録 A. 実験の再現

```sh
make deps && make bin/spinel lib/libspinel_rt.a
sh test/scale/gen.sh 400 > s400.rb
SP_TIMING=1 bin/spinel s400.rb -o s400 2>&1 | grep 'phase='      # §1.1
bin/spinel s400.rb -c --no-line-map -o s400.c
# §1.3 a: Model200#label の文字列を変える
awk '/^class Model200 < Base/{f=1} f && /def label = /{sub(/-#\{@tags.size\}/, "+#{@tags.size}"); f=0} {print}' s400.rb > e_a.rb
bin/spinel e_a.rb -c --no-line-map -o e_a.c && diff s400.c e_a.c | grep -c '^[<>]'
# §1.2: ヘッダだけの TU
printf '#include "spinel_rt.h"\nint main(void){return 0;}\n' > hdr.c
time cc -O2 -Wno-all -ffp-contract=off -Ilib -c hdr.c -o hdr.o
```

## 付録 B. 参照(一次資料)

- Crystal: `src/compiler/crystal/compiler.cr`(`CompilationUnit#must_compile?`);
  forum "Incremental compilation exploration"; A. Borenszweig, *Incremental
  compilation for Crystal* part 1 / 2 (dev.to); kojix2, *Why is Crystal
  compilation so slow?* (dev.to)
- Nim: `compiler/cgen.nim`(`shouldRecompile`)、`compiler/extccomp.nim`
  (`CfileFlag.Cached`, `writeJsonBuildInstructions`)、`compiler/ic/design.rst`
- Rust: rustc-dev-guide "Incremental compilation (in detail)";
  `compiler/rustc_monomorphize/src/partitioning.rs`; rustc book
  "Codegen options"(`codegen-units`, `incremental`)
- GHC: `compiler/GHC/Iface/Recomp.hs`; users guide "Separate compilation"
- Go: `cmd/go/internal/work/buildid.go`; `go help cache`
- Swift: `docs/DependencyAnalysis.md`; swift-driver
  `IncrementalCompilation/FirstWaveComputer.swift`, `Jobs/Planning.swift`
- Zig: ziglang/zig issue #21165(incremental tracking), PR #21629
- ccache `doc/manual.adoc`; ninja `doc/manual.asciidoc`(`restat`, `deps = gcc`)
- Chromium `docs/jumbo.md`, `build/config/jumbo.gni`; CMake `UNITY_BUILD`
- mypyc `mypyc/build.py`; Vala vala-list 2010-05 "incremental compilation";
  Nuitka tips "ccache"
- Salsa book "Algorithm"; Zinc: sbt reference "Incremental recompilation";
  Hack `hphp/hack/src/deps/typing_deps.ml`; Sorbet `docs/lsp.md`;
  Erdweg et al. OOPSLA 2015; Zwaan et al. OOPSLA 2022
