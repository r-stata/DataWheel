// DataWheel — 引擎调用（spawn Python engine.py）
import Foundation

struct DWError: Error {
    let message: String
    static func message(_ m: String) -> DWError { DWError(message: m) }
}

struct JobItem: Identifiable, Equatable {
    var id = UUID()
    let file: String
    let target: String
    var status: Status = .working
    var detail: String = "准备中…"
    var output: String? = nil
    var warning: String? = nil

    enum Status: Equatable { case working, done, failed }

    static func == (l: JobItem, r: JobItem) -> Bool { l.id == r.id }
}

final class Engine {
    static let shared = Engine()

    /// 定位 python 解释器：设置指定 -> 资源目录 venv（软链）-> 项目 venv -> homebrew
    static func pythonPath() -> String {
        if let p = Settings.load().pythonPath, !p.isEmpty, FileManager.default.fileExists(atPath: p) {
            return p
        }
        var candidates: [String] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent(".venv/bin/python").path)
        }
        // 开发态：源码目录下的 venv（native/Sources 相对项目根）
        candidates.append("/Users/ac/Desktop/数据格式转换应用/.venv/bin/python")
        candidates.append("/opt/homebrew/bin/python3")
        candidates.append("/usr/local/bin/python3")
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return "python3"
    }

    static func enginePath() -> String? {
        // 优先 bundle 资源，其次源码目录
        if let res = Bundle.main.resourceURL?.appendingPathComponent("engine/engine.py").path,
           FileManager.default.fileExists(atPath: res) { return res }
        let dev = "/Users/ac/Desktop/数据格式转换应用/engine/engine.py"
        if FileManager.default.fileExists(atPath: dev) { return dev }
        return nil
    }

struct EnvReport {
    let python: String
    let version: String
    let packages: [String: Bool]
    let missing: [String]
}

/// 检测 Python 依赖包（engine.py check）
static func checkEnv(onDone: @escaping (Result<EnvReport, DWError>) -> Void) {
    guard let engine = enginePath() else {
        onDone(.failure(DWError.message("找不到 engine.py"))); return
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: pythonPath())
    proc.arguments = [engine, "check"]
    proc.environment = ["PYTHONUNBUFFERED": "1"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do { try proc.run() } catch {
        onDone(.failure(DWError.message("无法启动 Python: \(error.localizedDescription)"))); return
    }
    proc.terminationHandler = { _ in
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            onDone(.failure(DWError.message("check 输出解析失败"))); return
        }
        let report = EnvReport(
            python: obj["python"] as? String ?? pythonPath(),
            version: obj["version"] as? String ?? "",
            packages: obj["packages"] as? [String: Bool] ?? [:],
            missing: obj["missing"] as? [String] ?? []
        )
        onDone(.success(report))
    }
}

    /// 安装缺失依赖包（engine.py install，逐行回调 pip 进度）
    static func installEnv(onLine: @escaping (String) -> Void,
                           onDone: @escaping (Result<(installed: [String], detail: String), DWError>) -> Void) {
        guard let engine = enginePath() else {
            onDone(.failure(DWError.message("找不到 engine.py"))); return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath())
        proc.arguments = [engine, "install"]
        proc.environment = ["PYTHONUNBUFFERED": "1"]
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        var buffer = Data()
        outPipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty { return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<nl])
                buffer.removeSubrange(buffer.startIndex...nl)
                if let s = String(data: line, encoding: .utf8) {
                    DispatchQueue.main.async { onLine(s) }
                }
            }
        }
        var stderr = ""
        errPipe.fileHandleForReading.readabilityHandler = { fh in
            if let s = String(data: fh.availableData, encoding: .utf8) { stderr += s }
        }

        do { try proc.run() } catch {
            onDone(.failure(DWError.message("无法启动 Python: \(error.localizedDescription)"))); return
        }
        proc.terminationHandler = { _ in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            var result: [String: Any]?
            // 最后一行 JSON
            let all = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            for line in (all + stderr).split(separator: "\n").reversed() {
                if let d = line.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   obj["ok"] != nil { result = obj; break }
            }
            DispatchQueue.main.async {
                guard let r = result else {
                    onDone(.failure(DWError.message("安装进程异常退出"))); return
                }
                if r["ok"] as? Bool == true {
                    onDone(.success((r["installed"] as? [String] ?? [],
                                     r["detail"] as? String ?? "安装完成")))
                } else {
                    onDone(.failure(DWError.message(r["detail"] as? String ?? "安装失败")))
                }
            }
        }
    }

    /// 调用引擎转换单个文件
    static func convert(file: String, target: String, outDir: String?, dtaLabel: String? = nil,
                        onStage: @escaping (String) -> Void,
                        onDone: @escaping (Result<(output: String, rows: Int, cols: Int, elapsed: Double, warning: String?), DWError>) -> Void) {
        guard let engine = enginePath() else {
            onDone(.failure(DWError.message("找不到 engine.py"))); return
        }
        var args = [engine, "convert", "--input", file, "--to", target]
        if let d = outDir { args += ["--out", d] }
        if let l = dtaLabel, !l.isEmpty { args += ["--label", l] }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath())
        proc.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.environment = ["PYTHONUNBUFFERED": "1", "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"]

        var buffer = Data()
        var allLines: [String] = []
        outPipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty { return }
            buffer.append(chunk)
            // 按行解析：阶段事件即时上报，全部行留存供结束后取结果
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<nl])
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let s = String(data: line, encoding: .utf8) else { continue }
                allLines.append(s)
                if let d = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   obj["event"] as? String == "stage", let stage = obj["stage"] as? String {
                    DispatchQueue.main.async { onStage(stage) }
                }
            }
        }

        var stderr = ""
        errPipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if let s = String(data: d, encoding: .utf8) { stderr += s }
        }

        do { try proc.run() } catch {
            onDone(.failure(DWError.message("无法启动 Python: \(error.localizedDescription)"))); return
        }

        proc.terminationHandler = { _ in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            // 取最后一行结果 JSON（stage 事件行除外）
            var result: [String: Any]?
            for line in allLines.reversed() {
                if let d = line.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   obj["event"] == nil { result = obj; break }
            }
            DispatchQueue.main.async {
                guard let r = result else {
                    let tail = String(stderr.suffix(300))
                    onDone(.failure(DWError.message(tail.isEmpty ? "转换进程异常退出" : tail))); return
                }
                if r["ok"] as? Bool == true, let output = r["output"] as? String {
                    onDone(.success((output,
                                     r["rows"] as? Int ?? 0,
                                     r["cols"] as? Int ?? 0,
                                     r["elapsed"] as? Double ?? 0,
                                     r["warning"] as? String)))
                } else {
                    onDone(.failure(DWError.message(r["error"] as? String ?? "转换失败")))
                }
            }
        }
    }
}
