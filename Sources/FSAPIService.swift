import Foundation

public struct RadioStatus {
    public var isPowerOn: Bool = false
    public var volume: Int = 0
    public var maxVolume: Int = 32
    public var isMuted: Bool = false
    public var currentMode: Int = 0
    public var modeName: String = "Internet Radio"
    public var nowPlayingName: String = ""
    public var nowPlayingText: String = ""
    public var friendlyName: String = ""
}

public class FSAPIService {
    public var host: String
    public var pin: String
    private var sessionID: String?
    
    public init(host: String, pin: String = "1234") {
        self.host = host
        self.pin = pin
    }
    
    // MARK: - Session Management
    
    public func createSession(completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "http://\(host)/fsapi/CREATE_SESSION?pin=\(pin)") else {
            completion(nil); return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3.0
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let data = data, error == nil, let xml = String(data: data, encoding: .utf8) else {
                completion(nil); return
            }
            if let sid = self?.extractValue(from: xml, tag: "sessionId") {
                self?.sessionID = sid
                completion(sid)
            } else {
                completion(nil)
            }
        }
        task.resume()
    }
    
    private func ensureSession(completion: @escaping (String?) -> Void) {
        if let sid = sessionID {
            completion(sid)
        } else {
            createSession(completion: completion)
        }
    }
    
    // MARK: - HTTP Helpers
    
    private func buildURL(endpoint: String, action: String = "GET", params: [String: String] = [:]) -> URL? {
        var components = URLComponents(string: "http://\(host)/fsapi/\(action)/\(endpoint)")
        var queryItems = [URLQueryItem(name: "pin", value: pin)]
        if let sid = sessionID {
            queryItems.append(URLQueryItem(name: "sid", value: sid))
        }
        for (k, v) in params {
            queryItems.append(URLQueryItem(name: k, value: v))
        }
        components?.queryItems = queryItems
        return components?.url
    }
    
    private func sendRequest(url: URL, completion: @escaping (String?) -> Void) {
        ensureSession { [weak self] _ in
            guard let finalURL = self?.buildURL(endpoint: url.pathComponents.suffix(1).joined(), action: url.pathComponents.contains("SET") ? "SET" : "GET") else {
                // Fallback to direct url
                self?.executeRequest(url: url, completion: completion)
                return
            }
            self?.executeRequest(url: finalURL, completion: completion)
        }
    }
    
    private func executeRequest(url: URL, completion: @escaping (String?) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3.0
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                completion(nil)
                return
            }
            let str = String(data: data, encoding: .utf8)
            completion(str)
        }
        task.resume()
    }
    
    // MARK: - XML Extractors
    
    private func extractValue(from xml: String, tag: String) -> String? {
        let pattern = "<\(tag)>(.*?)</\(tag)>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
           let match = regex.firstMatch(in: xml, options: [], range: NSRange(location: 0, length: xml.utf16.count)) {
            if let range = Range(match.range(at: 1), in: xml) {
                return String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
    
    private func extractFSAPIValue(from xml: String) -> String? {
        for tag in ["c8_array", "u8", "u16", "u32", "enum", "value"] {
            if let val = extractValue(from: xml, tag: tag) {
                return val
            }
        }
        return nil
    }
    
    // MARK: - API Calls
    
    public func fetchFriendlyName(completion: @escaping (String?) -> Void) {
        guard let url = buildURL(endpoint: "netRemote.sys.info.friendlyName") else { completion(nil); return }
        executeRequest(url: url) { [weak self] xml in
            guard let xml = xml else { completion(nil); return }
            let name = self?.extractFSAPIValue(from: xml)
            completion(name)
        }
    }
    
    public func fetchPower(completion: @escaping (Bool?) -> Void) {
        guard let url = buildURL(endpoint: "netRemote.sys.power") else { completion(nil); return }
        executeRequest(url: url) { [weak self] xml in
            guard let xml = xml, let valStr = self?.extractFSAPIValue(from: xml), let val = Int(valStr) else {
                completion(nil); return
            }
            completion(val == 1)
        }
    }
    
    public func setPower(_ turnOn: Bool, completion: @escaping (Bool) -> Void) {
        guard let url = buildURL(endpoint: "netRemote.sys.power", action: "SET", params: ["value": turnOn ? "1" : "0"]) else {
            completion(false); return
        }
        executeRequest(url: url) { xml in
            completion(xml?.contains("FS_OK") ?? false)
        }
    }
    
    public func fetchVolume(completion: @escaping (Int?) -> Void) {
        guard let url = buildURL(endpoint: "netRemote.sys.audio.volume") else { completion(nil); return }
        executeRequest(url: url) { [weak self] xml in
            guard let xml = xml, let valStr = self?.extractFSAPIValue(from: xml), let val = Int(valStr) else {
                completion(nil); return
            }
            completion(val)
        }
    }
    
    public func setVolume(_ level: Int, completion: @escaping (Bool) -> Void) {
        let clamped = max(0, min(32, level))
        guard let url = buildURL(endpoint: "netRemote.sys.audio.volume", action: "SET", params: ["value": "\(clamped)"]) else {
            completion(false); return
        }
        executeRequest(url: url) { xml in
            completion(xml?.contains("FS_OK") ?? false)
        }
    }
    
    public func fetchMute(completion: @escaping (Bool?) -> Void) {
        guard let url = buildURL(endpoint: "netRemote.sys.audio.mute") else { completion(nil); return }
        executeRequest(url: url) { [weak self] xml in
            guard let xml = xml, let valStr = self?.extractFSAPIValue(from: xml), let val = Int(valStr) else {
                completion(nil); return
            }
            completion(val == 1)
        }
    }
    
    public func setMute(_ mute: Bool, completion: @escaping (Bool) -> Void) {
        guard let url = buildURL(endpoint: "netRemote.sys.audio.mute", action: "SET", params: ["value": mute ? "1" : "0"]) else {
            completion(false); return
        }
        executeRequest(url: url) { xml in
            completion(xml?.contains("FS_OK") ?? false)
        }
    }
    
    public func fetchMode(completion: @escaping (Int?) -> Void) {
        guard let url = buildURL(endpoint: "netRemote.sys.mode") else { completion(nil); return }
        executeRequest(url: url) { [weak self] xml in
            guard let xml = xml, let valStr = self?.extractFSAPIValue(from: xml), let val = Int(valStr) else {
                completion(nil); return
            }
            completion(val)
        }
    }
    
    public func setMode(_ mode: Int, completion: @escaping (Bool) -> Void) {
        guard let url = buildURL(endpoint: "netRemote.sys.mode", action: "SET", params: ["value": "\(mode)"]) else {
            completion(false); return
        }
        executeRequest(url: url) { xml in
            completion(xml?.contains("FS_OK") ?? false)
        }
    }
    
    public func fetchNowPlaying(completion: @escaping (String?, String?) -> Void) {
        guard let urlName = buildURL(endpoint: "netRemote.play.info.name") else { completion(nil, nil); return }
        executeRequest(url: urlName) { [weak self] xmlName in
            let name = xmlName.flatMap { self?.extractFSAPIValue(from: $0) }
            guard let urlText = self?.buildURL(endpoint: "netRemote.play.info.text") else {
                completion(name, nil); return
            }
            self?.executeRequest(url: urlText) { xmlText in
                let text = xmlText.flatMap { self?.extractFSAPIValue(from: $0) }
                completion(name, text)
            }
        }
    }
    
    // VERIFIED WORKING PRESET SELECTION SEQUENCE:
    // 1. Session ID -> 2. Power ON -> 3. Mode 0 -> 4. Nav state 1 -> 5. Select Preset
    public func selectPreset(_ presetIndex: Int, completion: @escaping (Bool) -> Void) {
        // Always open a fresh session: the radio keeps only one, and the station catalog
        // (or UNDOK) may have replaced ours since it was cached.
        createSession { [weak self] sid in
            guard let self = self, let sid = sid else { completion(false); return }
            
            // Step 1: Power ON
            let powerURL = URL(string: "http://\(self.host)/fsapi/SET/netRemote.sys.power?pin=\(self.pin)&sid=\(sid)&value=1")!
            self.executeRequest(url: powerURL) { _ in
                
                // Step 2: Mode Internet Radio (0)
                let modeURL = URL(string: "http://\(self.host)/fsapi/SET/netRemote.sys.mode?pin=\(self.pin)&sid=\(sid)&value=0")!
                self.executeRequest(url: modeURL) { _ in
                    
                    // Step 3: Nav State 1
                    let navStateURL = URL(string: "http://\(self.host)/fsapi/SET/netRemote.nav.state?pin=\(self.pin)&sid=\(sid)&value=1")!
                    self.executeRequest(url: navStateURL) { _ in
                        
                        // Step 4: Select Preset
                        let presetURL = URL(string: "http://\(self.host)/fsapi/SET/netRemote.nav.action.selectPreset?pin=\(self.pin)&sid=\(sid)&value=\(presetIndex)")!
                        self.executeRequest(url: presetURL) { xml in
                            let success = xml?.contains("FS_OK") ?? false
                            completion(success)
                        }
                    }
                }
            }
        }
    }
    
    public func fetchAllStatus(completion: @escaping (RadioStatus?) -> Void) {
        var status = RadioStatus()
        let group = DispatchGroup()
        var hasError = false
        
        group.enter()
        fetchPower { power in
            if let p = power { status.isPowerOn = p } else { hasError = true }
            group.leave()
        }
        
        group.enter()
        fetchVolume { vol in
            if let v = vol { status.volume = v }
            group.leave()
        }
        
        group.enter()
        fetchMute { mute in
            if let m = mute { status.isMuted = m }
            group.leave()
        }
        
        group.enter()
        fetchMode { mode in
            if let m = mode { status.currentMode = m }
            group.leave()
        }
        
        group.enter()
        fetchNowPlaying { name, text in
            if let n = name { status.nowPlayingName = n }
            if let t = text { status.nowPlayingText = t }
            group.leave()
        }
        
        group.notify(queue: .main) {
            if hasError {
                completion(nil)
            } else {
                completion(status)
            }
        }
    }
}
