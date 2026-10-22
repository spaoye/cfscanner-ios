import Foundation

/// 结果上传：把测速结果按 exe 3.0 客户端协议上传到中转（broker），
/// 供 Emby 代理面板的自动优选拉取消费。格式规格见工程目录 upload-format-spec.md。
/// 本文件只负责 HTTP 与协议；开关关闭时 App 不会调用这里的任何方法。
enum Uploader {

    struct HTTPResult {
        let status: Int
        let json: [String: Any]?
    }

    /// POST JSON（单次）。返回 HTTP 状态码与解析出的 JSON（解析失败时 json 为 nil）。
    static func postJSON(urlString: String, headers: [String: String], body: [String: Any], timeout: TimeInterval = 30) async throws -> HTTPResult {
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "Uploader", code: -1, userInfo: [NSLocalizedDescriptionKey: "接口地址无效"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return HTTPResult(status: status, json: json)
    }

    static func headers(token: String) -> [String: String] {
        ["x-upload-token": token, "Content-Type": "application/json; charset=utf-8"]
    }

    /// 上传结果：最多 3 次尝试、间隔 2 秒（与 exe 一致）。成功返回中转确认保存的条数。
    static func upload(apiURL: String, token: String, body: [String: Any]) async -> Result<Int, String> {
        var lastError = "未知错误"
        for attempt in 1...3 {
            do {
                let r = try await postJSON(urlString: apiURL, headers: headers(token: token), body: body)
                guard r.status == 200 else {
                    lastError = "中转拒绝上传：HTTP \(r.status)"
                    if let e = r.json?["error"] as? String, !e.isEmpty { lastError += "（\(e)）" }
                    if attempt < 3 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                    continue
                }
                guard let json = r.json else {
                    lastError = "中转未返回有效的 JSON"
                    if attempt < 3 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                    continue
                }
                if (json["ok"] as? Bool) == true {
                    return .success((json["saved"] as? Int) ?? -1)
                }
                lastError = "中转返回失败：\((json["error"] as? String) ?? "ok 不为 true")"
                if attempt < 3 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            } catch {
                lastError = "网络错误：\(error.localizedDescription)"
                if attempt < 3 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            }
        }
        return .failure(lastError)
    }

    /// 验证令牌：上传地址路径换成 verifyUploadToken，成功返回中转登记的客户端名。
    static func verifyToken(apiURL: String, token: String) async -> Result<String, String> {
        let verifyURL: String
        if apiURL.contains("uploadResult") {
            verifyURL = apiURL.replacingOccurrences(of: "uploadResult", with: "verifyUploadToken")
        } else {
            verifyURL = apiURL.hasSuffix("/") ? apiURL + "verifyUploadToken" : apiURL + "/verifyUploadToken"
        }
        do {
            let r = try await postJSON(urlString: verifyURL, headers: headers(token: token), body: ["type": "v4"])
            guard r.status == 200, let json = r.json else {
                return .failure("验证失败：HTTP \(r.status)")
            }
            if (json["ok"] as? Bool) == true {
                let client = json["client"] as? [String: Any]
                let name = (client?["name"] as? String) ?? ""
                return .success(name)
            }
            return .failure("验证失败：\((json["error"] as? String) ?? "令牌不被接受")")
        } catch {
            return .failure("无法连接验证接口：\(error.localizedDescription)")
        }
    }
}
