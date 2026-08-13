// =====================================================================
//  qos-DOE.swift — does Thread.qualityOfService reach the underlying QoS class?
//  qos-DOE.swift — Thread.qualityOfService 是否真的傳達到底層 QoS class？
//
//  Setting `Thread.current.qualityOfService` on a command-line tool's main
//  thread appears not to change `qos_class_self()`, while
//  `pthread_set_qos_class_self_np` does. If that holds, code that tunes
//  scheduling through Foundation is silently a no-op, and any benchmark that
//  relies on it is comparing threads it believes are equal but are not.
//  在命令列工具的主執行緒上設定 `Thread.current.qualityOfService`，似乎不會改變
//  `qos_class_self()`，而 `pthread_set_qos_class_self_np` 會。若此成立，透過
//  Foundation 調整排程的程式其實是靜默的無操作，而任何依賴它的量測，都在比較它
//  以為相同、實則不同的執行緒。
//
//  This is a reproducer, not a benchmark. It separates the two questions:
//    1. Does the API change the reported class?  — exact, not timing-dependent
//    2. Does the class change throughput?        — timed, and therefore noisy
//  本程式是重現案例而非效能量測。它將兩個問題分開：
//    1. 該 API 是否改變所回報的類別？—— 精確，不依賴計時
//    2. 該類別是否改變吞吐量？      —— 需計時，因而有雜訊
//
//  Question 1 is the claim worth reporting: it is a boolean, observed directly
//  from qos_class_self(), with no timing involved. Question 2 is included only
//  to show the class is not merely cosmetic, and its measurements are
//  interleaved because a naive sequential sweep is contaminated by the previous
//  arm — a background arm that runs for ten seconds leaves the machine in a
//  different state than it found it.
//  問題 1 才是值得回報的主張：它是布林值，直接由 qos_class_self() 觀察，不涉及
//  計時。問題 2 僅用於證明該類別並非僅具裝飾性，且其量測採交錯進行，因為單純的
//  循序掃描會被前一組污染——跑了十秒的 background 組會讓機器停在與開始時不同的
//  狀態。
//
//  Build / 建置:
//    swiftc -O qos-DOE.swift -o qos-DOE
//  Usage / 用法:
//    ./qos-DOE [iterations-per-sample] [rounds]
// =====================================================================

import Foundation
import Darwin

let usage = """
qos-DOE — does Thread.qualityOfService reach the underlying QoS class?
qos-DOE — Thread.qualityOfService 是否真的傳達到底層 QoS class？

Usage / 用法:
  qos-DOE [--iterations N] [--rounds N] [--skip-timing] [--help]

  --iterations N   work per sample; raise it if the timings are under a few ms,
                   lower it if a run takes too long (default 8000000)
                   每次取樣的工作量；計時低於數毫秒時調高，執行過久時調低
  --rounds N       interleaved rounds per class; more rounds, less noise
                   (default 7)
                   每個類別交錯執行的輪數；輪數越多雜訊越小
  --skip-timing    report only the class observations, which are exact and take
                   under a second — use this when reporting the API behaviour
                   僅回報類別觀察結果；該部分精確且耗時不到一秒，回報 API 行為
                   時使用
  --help           this text; also shown when no flag is given
                   本說明；未帶任何旗標時亦顯示此內容

  Run the class check alone / 僅執行類別檢查:   qos-DOE --skip-timing
  Run everything at defaults / 以預設值全部執行: qos-DOE --rounds 7

Notes / 注意:
  Section 1 is the reportable claim: it reads qos_class_self() directly and does
  not depend on timing, so it reproduces identically on any machine.
  Section 2 exists only to show the class is not cosmetic. It is timing-based
  and therefore machine- and load-dependent; run it on an otherwise idle system.
  第 1 節才是可回報的主張：它直接讀取 qos_class_self()，不依賴計時，故在任何機器
  上都能一致重現。第 2 節僅用於證明該類別並非裝飾性；它基於計時，因而受機器與
  負載影響，請在系統閒置時執行。
"""

func intFlag(_ name: String, _ fallback: Int) -> Int {
    let argv = CommandLine.arguments
    guard let i = argv.firstIndex(of: name) else { return fallback }
    guard i + 1 < argv.count, let v = Int(argv[i + 1]), v > 0 else {
        FileHandle.standardError.write(Data("[Error] \(name) needs a positive integer / 需要正整數\n".utf8))
        exit(2)
    }
    return v
}

// A bare invocation prints usage rather than launching a timed sweep: someone
// running this for the first time is reading, not measuring, and the timing
// section can take a minute on a slow class.
// 未帶旗標時印出用法而非直接啟動計時掃描：初次執行者是在閱讀而非量測，而計時
// 一節在較慢的類別上可能耗時一分鐘。
if CommandLine.arguments.count == 1
    || CommandLine.arguments.contains("--help")
    || CommandLine.arguments.contains("-h") {
    print(usage)
    exit(0)
}
for arg in CommandLine.arguments.dropFirst()
where arg.hasPrefix("-") && !["--iterations", "--rounds", "--skip-timing"].contains(arg) {
    FileHandle.standardError.write(Data("[Error] unknown flag \(arg) — see --help\n".utf8))
    exit(2)
}

let iterations = intFlag("--iterations", 8_000_000)
let rounds = intFlag("--rounds", 7)
let skipTiming = CommandLine.arguments.contains("--skip-timing")

// Columns are padded in Swift rather than with String(format: "%s", ...): the
// pointer from (s as NSString).utf8String belongs to a temporary that is
// released before printf reads it, which is a use-after-free that segfaults
// before stdout is ever flushed — the program appears to produce no output at
// all rather than to crash in a legible place.
// 欄位以 Swift 補位而非 String(format: "%s", ...)：(s as NSString).utf8String 取得
// 的指標屬於一個在 printf 讀取前即被釋放的臨時物件，形成 use-after-free，且在
// stdout 被 flush 之前就 segfault——程式看起來完全沒有輸出，而非在可辨識處崩潰。
func pad(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
}

func className(_ c: qos_class_t) -> String {
    switch c {
    case QOS_CLASS_USER_INTERACTIVE: return "userInteractive"
    case QOS_CLASS_USER_INITIATED:   return "userInitiated"
    case QOS_CLASS_DEFAULT:          return "default"
    case QOS_CLASS_UTILITY:          return "utility"
    case QOS_CLASS_BACKGROUND:       return "background"
    case QOS_CLASS_UNSPECIFIED:      return "unspecified"
    default:                         return "unknown(\(c.rawValue))"
    }
}

// ---------------------------------------------------------------------
// MARK: - Question 1: does the API change the reported class?
// MARK: - 問題 1：該 API 是否改變所回報的類別？
// ---------------------------------------------------------------------

print("== 1. Reported class after each API / 各 API 呼叫後所回報的類別 ==")
print("   Exact observation via qos_class_self(); no timing involved.")
print("   以 qos_class_self() 精確觀察，不涉及計時。")
print("")

var findings: [(String, String, String, Bool)] = []   // api, before, after, changed

func probe(_ label: String, _ apply: () -> Void) {
    let before = className(qos_class_self())
    apply()
    let after = className(qos_class_self())
    findings.append((label, before, after, before != after))
}

probe("Thread.current.qualityOfService = .utility") {
    Thread.current.qualityOfService = .utility
}
probe("Thread.current.qualityOfService = .background") {
    Thread.current.qualityOfService = .background
}
probe("Thread.current.qualityOfService = .userInitiated") {
    Thread.current.qualityOfService = .userInitiated
}
probe("pthread_set_qos_class_self_np(UTILITY)") {
    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0)
}
probe("pthread_set_qos_class_self_np(USER_INITIATED)") {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)
}

print(pad("api", 50) + pad("before", 16) + pad("after", 16) + "changed")
print(String(repeating: "-", count: 92))
for (api, before, after, changed) in findings {
    print(pad(api, 50) + pad(before, 16) + pad(after, 16) + (changed ? "yes" : "NO"))
}

// The same two APIs on a secondary Thread, since the main thread of a CLI tool
// may be a special case and a report should say which.
// 於次要 Thread 上執行同樣兩個 API，因為 CLI 工具的主執行緒可能屬特例，回報時
// 應指明適用範圍。
print("")
print("   On a secondary Thread, set from inside the running thread /")
print("   於次要 Thread 內部設定:")
let done = DispatchSemaphore(value: 0)
let t = Thread {
    let launched = className(qos_class_self())
    Thread.current.qualityOfService = .utility
    let afterFoundation = className(qos_class_self())
    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0)
    let afterPthread = className(qos_class_self())
    print("     launched=\(launched)  afterThreadProperty=\(afterFoundation)  afterPthread=\(afterPthread)")
    done.signal()
}
t.start()
done.wait()

// The documented usage is to set qualityOfService before start(), so the
// property must be tested that way before any of this is called a defect. If
// this arm works, the property is merely start-time-only and the finding is a
// documentation matter rather than a bug.
// 文件建議的用法是在 start() 之前設定 qualityOfService，故在將此稱為缺陷之前，
// 必須先以該方式測試。若本組有效，該屬性僅是「只在啟動時生效」，此發現便屬文件
// 層面而非缺陷。
print("")
print("   On a secondary Thread, set BEFORE start() — the documented usage /")
print("   於次要 Thread 啟動前設定 —— 文件所載用法:")
let done2 = DispatchSemaphore(value: 0)
var observedBeforeStart = "(not run)"
let t2 = Thread {
    observedBeforeStart = className(qos_class_self())
    done2.signal()
}
t2.qualityOfService = .utility
t2.start()
done2.wait()
print("     set .utility before start() -> qos_class_self = \(observedBeforeStart)"
      + (observedBeforeStart == "utility" ? "   (takes effect / 生效)"
                                          : "   (NO effect / 未生效)"))

// ---------------------------------------------------------------------
// MARK: - Question 2: does the class change throughput?
// MARK: - 問題 2：該類別是否改變吞吐量？
// ---------------------------------------------------------------------

/// A dependent chain so the core's effective clock shows through. The argument
/// varies per call because the optimiser will otherwise prove the function pure
/// and evaluate it once, leaving every repeat but the first at zero.
/// 相依運算鏈，使核心的有效時脈得以顯現。引數需逐次改變，否則最佳化器會證明此
/// 函式為純函式而只求值一次，使首次以外的每次重複皆為零。
@inline(never) func spin(_ n: Int) -> Int {
    var acc = 1
    for i in 0..<n { acc = (acc &* 31 &+ i) & 0xFFFFFF }
    return acc
}

var sink = 0
var samples: [qos_class_t: [Double]] = [:]
let arms: [(String, qos_class_t)] = [
    ("userInitiated", QOS_CLASS_USER_INITIATED),
    ("utility",       QOS_CLASS_UTILITY),
    ("background",    QOS_CLASS_BACKGROUND),
]

if skipTiming {
    print("")
    print("== 2. Throughput per class — skipped (--skip-timing) / 已略過 ==")
    reportVerdict()
    exit(0)
}

print("")
print("== 2. Throughput per class / 各類別的吞吐量 ==")
print("   Arms are interleaved across \(rounds) rounds, not run end to end: a")
print("   sequential sweep lets one arm's thermal and scheduler aftermath land")
print("   on the next. Median is reported; the min of a contaminated series is")
print("   not obviously the honest value.")
print("   各組於 \(rounds) 輪中交錯執行而非各自跑完：循序掃描會讓某一組的熱與排程")
print("   後效落在下一組上。回報中位數；受污染序列的最小值未必是誠實的值。")
print("")

for round in 0..<rounds {
    for (_, cls) in arms {
        pthread_set_qos_class_self_np(cls, 0)
        let t0 = Date()
        sink &+= spin(iterations + round)
        samples[cls, default: []].append(Date().timeIntervalSince(t0) * 1000)
    }
}
pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

func rpad(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
}

print(pad("class", 18) + rpad("median ms", 12) + rpad("min ms", 12) + rpad("max ms", 12))
print(String(repeating: "-", count: 56))
var baseline = 0.0
for (name, cls) in arms {
    let xs = samples[cls] ?? []
    guard !xs.isEmpty else { continue }
    let m = median(xs)
    if baseline == 0 { baseline = m }
    print(pad(name, 18) + rpad(String(format: "%.1f", m), 12)
          + rpad(String(format: "%.1f", xs.min()!), 12)
          + rpad(String(format: "%.1f", xs.max()!), 12)
          + String(format: "   %.1fx", m / baseline))
}

reportVerdict()

/// Both exit paths end here — the full run and --skip-timing — so the
/// reportable conclusion is worded once.
/// 兩條結束路徑（完整執行與 --skip-timing）皆匯集於此，使可回報的結論只有一種
/// 措辭。
func reportVerdict() {
    print("")
    print("== Verdict / 結論 ==")
    let foundationWorks = findings.filter { $0.0.hasPrefix("Thread.") }.contains { $0.3 }
    let pthreadWorks = findings.filter { $0.0.hasPrefix("pthread_") }.contains { $0.3 }
    print("  Thread.qualityOfService on a RUNNING thread changes qos_class_self(): "
          + (foundationWorks ? "yes" : "NO"))
    print("  Thread.qualityOfService set BEFORE start():                          "
          + (observedBeforeStart == "utility" ? "yes" : "NO"))
    print("  pthread_set_qos_class_self_np:                                       "
          + (pthreadWorks ? "yes" : "NO"))
    print("")
    if !foundationWorks && observedBeforeStart == "utility" {
        // Not a defect: the property is a thread-creation attribute, and this is
        // the documented usage. What it is not is a live control — and the main
        // thread is always already running, so it can never be configured this
        // way. The one thing worth raising is that assigning to a running
        // thread's property fails silently.
        // 並非缺陷：該屬性是執行緒建立時的屬性，且此為文件所載用法。它不是即時
        // 控制——而主執行緒永遠處於執行中，故無法以此方式設定。唯一值得提出的是：
        // 對執行中執行緒的該屬性賦值會靜默失敗。
        print("  Thread.qualityOfService works as documented: it is a creation-time")
        print("  attribute, effective when set before start(). It is not a live")
        print("  control, and assigning it to an already-running thread is a silent")
        print("  no-op with no error and no warning.")
        print("")
        print("  The main thread is always already running, so it cannot be")
        print("  configured through this property at all; pthread_set_qos_class_self_np")
        print("  is the only option there. Code that sets it on the main thread and")
        print("  assumes it took effect is measuring or scheduling something other")
        print("  than what it believes.")
        print("")
        print("  Thread.qualityOfService 的行為與文件一致：它是建立時的屬性，於")
        print("  start() 之前設定即生效。它不是即時控制，對已在執行的執行緒賦值")
        print("  是靜默的無操作，既不報錯也不警告。")
        print("  主執行緒永遠處於執行中，故完全無法透過該屬性設定；該處唯一的選項")
        print("  是 pthread_set_qos_class_self_np。在主執行緒上設定它並假設已生效的")
        print("  程式，其量測或排程的對象與它所以為的並不相同。")
    } else if !foundationWorks && !pthreadWorks {
        print("  Neither API changed the class; the reading itself may be suspect.")
        print("  兩個 API 皆未改變類別；此讀數本身可能不可信。")
    }
    print("")
    print("  swift: \(swiftVersion())  cores: \(ProcessInfo.processInfo.activeProcessorCount)")
    print("  macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
}

func swiftVersion() -> String {
    #if swift(>=6.0)
    return ">=6.0"
    #elseif swift(>=5.0)
    return ">=5.0"
    #else
    return "<5.0"
    #endif
}
