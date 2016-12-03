//
//  NewtManager.swift
//  NewtManager
//
//  Created by Antonio García on 02/12/2016.
//  Copyright © 2016 Adafruit. All rights reserved.
//

import UIKit


protocol NewtStateDelegate: class {
    func onNewtWrite(data: Data, completion: NewtManager.RequestCompletionHandler?)
}

class NewtManager {
    
    // Types
    typealias RequestCompletionHandler = ((_ data: Any?, _ error: Error?) -> Void)
    typealias RequestProgressHandler = ((_ progress: Float) -> Bool)    // Return value indicates if the operation should be cancelled
    
    // Data Structures
    enum Command {
        case imageList
        case imageTest(hash: Data)
        case imageConfirm(hash: Data?)
        case upload(imageData: Data)
        case taskStats
        case reset
        case echo(message: String)
        case stats
        case stat(statId: String)
    }
    
    struct TaskStats {
        var taskId: UInt
        var name: String
        var priority: UInt
        var state: UInt
        var runTime: UInt
        var contextSwichCount: UInt
        var stackSize: UInt
        var stackUsed: UInt
        var lastSanityCheckin: UInt
        var nextSanityCheckin: UInt
    }
    
    struct StatDetails {
        var name: String
        var value: UInt
    }
    
    enum NewtError: Error {
        case receivedResponseIsNotAPacket
        case receivedResponseIsNotACbor(Error?)
        case receivedResponseMissingFields
        case receviedResponseInvalidValues
        case receivedResultNotOk(String)
        case internalError
        case updateImageInvalid
        case imageInvalid
        case userCancelled
        case waitingForReponse
        
        var description: String {
            switch self {
            case .receivedResponseIsNotAPacket: return "Received response is not a packet"
            case .receivedResponseIsNotACbor(let error): return "Received invalid response: \(error?.localizedDescription ?? "")"
            case .receivedResponseMissingFields: return "Received response with missing fields"
            case .receviedResponseInvalidValues: return "Received response with invalid values"
            case .receivedResultNotOk(let message): return "Received incorrect result: \(message)"
            case .internalError: return "Internal error"
            case .updateImageInvalid: return "Upload image is invalid"
            case .imageInvalid: return "Image invalid"
            case .userCancelled: return "Cancelled"
            case .waitingForReponse: return "Waiting for previous command"
            }
        }
    }

    
    // MARK: - Packet
    struct Packet {
        enum Flags: UInt8 {
            case none               = 0
            case responseComplete   = 1
            
            var code: UInt8 {
                return rawValue
            }
        }
        
        enum OpCode: UInt8 {
            case read           = 0
            case readResponse   = 1
            case write          = 2
            case writeResponse  = 3
            
            var code: UInt8 {
                return rawValue
            }
        }
        
        enum Group: UInt16 {
            case `default`    = 0
            case image      = 1
            case stats      = 2
            
            /*
             case config     = 3
             case logs       = 4
             case crash      = 5
             case peruser    = 64
             */
            var code: UInt16 {
                return rawValue
            }
        }
        
        
        enum GroupDefault: UInt8 {
            case echo           = 0
            case taskStats      = 2
            
            /*
             case ConsEchoCtrl   = 1
             case Mpstats        = 3
             case DatetimeStr    = 4
             */
            case reset          = 5
            
            var code: UInt8 {
                return rawValue
            }
        }
        
        enum GroupImage: UInt8 {
            case list       = 0
            case upload     = 1
            
            /*
             case Boot       = 2
             case File       = 3
             case List2      = 4
             case Activate   = 5
             case Corelist   = 6
             case Coreload   = 7
             */
            
            var code: UInt8 {
                return rawValue
            }
        }
        
        enum GroupStats: UInt8 {
            case statDetails    = 0
            case stats          = 1
            
            var code: UInt8 {
                return rawValue
            }
        }
        
        enum ReturnCode: UInt16 {
            case ok        = 0
            case unknown   = 1
            case nomem     = 2
            case inval     = 3
            case timeout   = 4
            case nonent    = 5
            case peruser   = 256
            
            var description: String {
                switch self {
                case .ok: return "Success"
                case .unknown: return "Unknown Error: Command might not be supported"
                case .nomem:  return "Out of memory"
                case .inval: return "Device is in invalid state"
                case .timeout: return "Operation Timeout"
                case .nonent: return "Enoent"
                case .peruser: return "Peruser"
                }
            }
            
            var code: UInt16 {
                return rawValue
            }
        }
        
        var op: OpCode
        var flags: Flags
        var len: UInt16 {
            return UInt16(data.count)
        }
        var group: Group
        var seq: UInt8
        var id: UInt8
        var data: Data
        
        // MARK:
        init (op: OpCode, group: Group, id: UInt8) {
            self = Packet(op: op, flags: .none, group: group, seq: 0, id: id)
        }
        
        init(op: OpCode, flags: Flags, group: Group, seq:UInt8, id: UInt8, data: Data = Data()) {
            self.op    = op
            self.flags = flags
            self.group = group
            self.seq   = seq
            self.id    = id
            self.data  = data
        }
        
        func encode(data: Data?) -> Data {
            struct ArchivedPacket {
                var op   : UInt8
                var flags: UInt8
                var len  : UInt16
                var group: UInt16
                var seq  : UInt8
                var id   : UInt8
            }
            
            let dataLen = UInt16(data?.count ?? 0)
            var archivedNmgrPacket = ArchivedPacket(op: op.code, flags: flags.code, len: dataLen.byteSwapped, group: group.code.byteSwapped, seq: seq, id: id)
            
            let packetSize = MemoryLayout.size(ofValue: archivedNmgrPacket)
            var packet = Data(capacity: packetSize)
            packet.append(UnsafeBufferPointer(start: &archivedNmgrPacket, count: 1))
            if let data = data {
                packet.append(data)
            }
            
            return packet
        }
    }
    
    struct Request {
        var command: Command
        var progress: RequestProgressHandler?
        var completion: RequestCompletionHandler?
        
        init(command: Command, progress: RequestProgressHandler?, completion: RequestCompletionHandler?) {
            self.command = command
            self.progress = progress
            self.completion = completion
        }
        
        static let uploadPacket = Packet(op: Packet.OpCode.write, group: Packet.Group.image, id: Packet.GroupImage.upload.code)
        
        var packet: Packet {
            var packet: Packet
            
            switch command {
            case .imageList:
                packet = Packet(op: Packet.OpCode.read, group: Packet.Group.image, id: Packet.GroupImage.list.code)
                
            case .imageTest, .imageConfirm:
                packet = Packet(op: Packet.OpCode.write, group: Packet.Group.image,  id: Packet.GroupImage.list.code)
                
            case .upload:
                packet = Request.uploadPacket
                
            case .taskStats:
                packet = Packet(op: Packet.OpCode.read, group: Packet.Group.default,  id: Packet.GroupDefault.taskStats.code)
                
            case .reset:
                packet = Packet(op: Packet.OpCode.write, group: Packet.Group.default, id: Packet.GroupDefault.reset.code)
                
            case .echo:
                packet = Packet(op: Packet.OpCode.write, group: Packet.Group.default, id: Packet.GroupDefault.echo.code)
                
            case .stats:
                packet = Packet(op: Packet.OpCode.read, group: Packet.Group.stats, id: Packet.GroupStats.stats.code)
                
            case .stat:
                packet = Packet(op: Packet.OpCode.read, group: Packet.Group.stats,  id: Packet.GroupStats.statDetails.code)
                
            }
            
            return packet
        }
    }

    
    struct Response {
        var packet: Packet!
        
        var description: String {
            return packet != nil ? "Nmgr Response (Op Code = \(packet!.op.rawValue) Group = \(packet!.group.rawValue) Id = \(packet!.id))" : "<undefined packet>"
        }
        
        init?(_ data: Data) {
            guard let decodedPacket = Response.decode(data: data) else {
                return nil
            }
            
            packet = decodedPacket
        }
        
        private static func decode(data: Data) -> Packet? {
            let op: UInt8 = data.scanValue(start: 0, length: 1)
            let flagsValue: UInt8 = data.scanValue(start: 1, length: 1)
            var bytesReceived: UInt16 = data.scanValue(start: 2, length: 2)
            bytesReceived = (UInt16(bytesReceived)).byteSwapped
            var groupValue: UInt16 = data.scanValue(start: 4, length: 2)
            groupValue = (UInt16(groupValue)).byteSwapped
            let seq: UInt8 = data.scanValue(start: 6, length: 1)
            let id: UInt8 = data.scanValue(start: 7, length: 1)
            
            let kDataOffset = 8
            if Int(bytesReceived) > data.count-kDataOffset {
                DLog("Warning: received lenght is bigger that packet size")
                bytesReceived = min(bytesReceived, UInt16(data.count-kDataOffset))
            }
            
            let pktData = data.subdata(in: kDataOffset..<kDataOffset+Int(bytesReceived))
            
            guard  let opcode = Packet.OpCode(rawValue: op), let flags = Packet.Flags(rawValue: flagsValue), let group = Packet.Group(rawValue: groupValue) else {
                DLog("Error: invalid Response packet values")
                return nil
            }
            
            let packet = Packet(op: opcode, flags: flags, /*len: bytesReceived, */group: group, seq: seq, id: id, data: pktData)
            if bytesReceived != packet.len {
                DLog("Warning: mismatch in packet lenght reported")
            }
            return packet
        }
    }
    
    // MARK: - 
    
    private var newtRequestsQueue: CommandQueue<NewtManager.Request>  =  CommandQueue<NewtManager.Request>()
    private var newtResponseCache = Data()

    weak var delegate: NewtStateDelegate?
    
    init() {
        newtRequestsQueue.executeHandler = executeRequest
    }
    
    func start() {
        newtResponseCache.removeAll()

    }
    
    func stop() {
        newtRequestsQueue.removeAll()
        newtResponseCache.removeAll()
    }
    
    // MARK: - Send Request
    func sendRequest(with command: NewtManager.Command, progress: NewtManager.RequestProgressHandler? = nil, completion: NewtManager.RequestCompletionHandler?) {
        let request = NewtManager.Request(command: command, progress: progress, completion: completion)
        newtRequestsQueue.append(request)
    }
    
    // MARK: - Execute Request
    private func executeRequest(request: NewtManager.Request) {
        
        guard newtResponseCache.isEmpty else {
            DLog("Error: trying to send command while waiting for response")
            request.completion?(nil, NewtManager.NewtError.waitingForReponse)
            newtRequestsQueue.next()
            return
        }
        
        var data: Data?
        switch request.command {
        case let .imageTest(hash: hash):
            let dataDictionary: [String: Any] = ["confirm": false, "hash": hash]
            data = NewtManager.encodeCbor(dataDictionary: dataDictionary)
            
        case let .imageConfirm(hash: hash):
            var dataDictionary: [String: Any] = ["confirm": true]
            if let hash = hash {
                dataDictionary["hash"] =  hash
            }
            else {
                dataDictionary["hash"] = NSNull()
            }
            data = NewtManager.encodeCbor(dataDictionary: dataDictionary)
            
        case .upload(let imageData):
            data = newtUpload(imageData: imageData, progress: request.progress, completion: request.completion)
            
        case .echo(let message):
            let dataDictionary: [String: Any] = ["d": message]
            data = NewtManager.encodeCbor(dataDictionary: dataDictionary)
            
        case .stat(let statId):
            let dataDictionary: [String: Any] = ["name": statId]
            data = NewtManager.encodeCbor(dataDictionary: dataDictionary)
            
        default:
            data = nil
        }
        
        let requestPacketData = request.packet.encode(data: data)
        
        DLog("Send Command: Op:\(request.packet.op.rawValue) Flags:\(request.packet.flags.rawValue) Len:\(data?.count ?? 0) Group:\(request.packet.group.rawValue) Seq:\(request.packet.seq) Id:\(request.packet.id) Data:[\(data != nil ? hexDescription(data: data!):"")]")
        
        delegate?.onNewtWrite(data: requestPacketData) { [weak self] (_, error) in
            if error != nil {
                request.completion?(nil, error)
                self?.newtRequestsQueue.next()
            }
        }
    }
    
    // MARK: Upload
    private func newtUpload(imageData: Data, progress: NewtManager.RequestProgressHandler?, completion: NewtManager.RequestCompletionHandler?) -> Data? {
        guard imageData.count >= 32 else {
            completion?(nil, NewtManager.NewtError.updateImageInvalid)
            newtRequestsQueue.next()
            return nil
        }
        
        // Start uploading the first packet (it will continue uploading packets step by step each time a notification is received)
        return newtUploadPacketData(from: imageData, offset: 0, progress: progress, completion: completion)
    }
    
    
    private func newtUploadPacketData(from imageData: Data, offset dataOffset: Int, progress: NewtManager.RequestProgressHandler?, completion: NewtManager.RequestCompletionHandler?) -> Data? {
        
        // Update progress
        var isCancelled = false
        if let progress = progress {
            let currentProgress = Float(dataOffset) / Float(imageData.count)
            isCancelled = progress(currentProgress)
        }
        
        var packetData: Data? = nil
        
        if isCancelled {                                // Cancelled
            completion?(nil, NewtManager.NewtError.userCancelled)
            newtRequestsQueue.next()
        }
        else if imageData.count - dataOffset <= 0 {     // Finished
            completion?(nil, nil)
            newtRequestsQueue.next()
        }
        else {                                          // Create packet data
            packetData = NewtManager.createUploadPacketData(with: imageData, packetOffset: dataOffset)
        }
        
        return packetData
    }

    
    static func createUploadPacketData(with firmwareData: Data, packetOffset: Int) -> Data? {
        
        // Calculate bytes to send
        //let kMaxPacketSize = 56 // 76
        let isFirstPacket = packetOffset == 0
        let maxPacketSize =  153 - (isFirstPacket ? 7:0)
        
        let firmwareSize = firmwareData.count
        let remainingBytes = firmwareSize - packetOffset
        
        var bytesToSend: Int
        if remainingBytes >= maxPacketSize {
            bytesToSend = maxPacketSize
        }
        else {
            bytesToSend = remainingBytes % maxPacketSize
        }
        
        // Create data to send
        let packetData = firmwareData.subdata(in: packetOffset..<packetOffset+bytesToSend)
        var dataDictionary: [String: Any] = ["off": packetOffset, "data": packetData]
        if isFirstPacket {
            dataDictionary["len"] = firmwareSize
        }
        let encodedData = encodeCbor(dataDictionary: dataDictionary)
        
        return encodedData
    }
    
    private static func encodeCbor(dataDictionary: Dictionary<String, Any>) -> Data? {
        guard let cbor = CBOR(rawValue: dataDictionary) else {
            DLog("Error generating CBOR")
            return nil
        }
        
        DLog("------");
        DLog("Prepare CBOR payload: \(cbor.description)")
        
        var encodedData: Data?
        do {
            encodedData = try CBOREncoder().encodeItemAsData(cbor: cbor)
        }
        catch {
            DLog("Error encoding packet: \(error)")
        }
        
        return encodedData
    }
    
    
    // MARK: - Receive Response
    func newtReceivedData(data: Data?, error: Error?) {
        //DLog("Raw data: \(hexDescription(data: data ?? Data()))")
        
        // Check timeout
        
        
        // Check data
        guard let data = data, error == nil else {
            DLog("Error reading newt data: \(error)")
            responseError(error: error)
            return
        }
        
        // Check response is valid
        guard let response = NewtManager.Response(data) else {
            DLog("Error parsing newt data: \(hexDescription(data: data))")
            responseError(error: NewtManager.NewtError.receivedResponseIsNotAPacket)
            return
        }
        
        // Get command
        guard let command = newtRequestsQueue.first()?.command else {
            DLog("Warning: newtReadData with no command")
            return
        }
        
        // Read data
        DLog("Received: Op: \(response.packet.op) Flags: \(response.packet.flags) Len: \(response.packet.len) Group: \(response.packet.group) Seq: \(response.packet.seq) Id: \(response.packet.id) data: [\(hexDescription(data: response.packet.data))]")
        
        newtResponseCache.append(response.packet.data)
        
        guard response.packet.flags == .responseComplete else {
            DLog("cache size: \(newtResponseCache.count). Waiting next packet...")
            return
        }
        
        // Decode CBOR
        var cbor: CBOR?
        do {
            cbor = try CBORDecoder(data: newtResponseCache).decodeItem()
        }
        catch {
            DLog("Error: Can't decode CBOR")
        }
        
        // Remove cached data
        newtResponseCache.removeAll()
        
        // Process response
        if let cbor = cbor {
            DLog("Received CBOR: \(cbor)")
            
            // Parse response
            switch command {
            case .imageList, .imageTest, .imageConfirm:
                parseResponseImageList(cbor: cbor)
            case .echo:
                parseEcho(cbor: cbor)
            case .upload(let imageData):
                parseResponseUploadImage(cbor: cbor, imageData: imageData)
            case .taskStats:
                parseResponseTaskStats(cbor: cbor)
            case .stats:
                parseResponseStats(cbor: cbor)
            case .stat:
                parseResponseStatDetails(cbor: cbor)
                
            default:
                parseBasicResponse(cbor: cbor)
            }
        }
        else {
            DLog("Error: CBOR is nil")
        }
    }
    
    // MARK: List, Test, Confirm
    
    private func parseResponseImageList(cbor: CBOR) {
        defer {
            newtRequestsQueue.next()
        }
        
        let completionHandler = newtRequestsQueue.first()?.completion
        guard NewtManager.verifyResponseCode(cbor: cbor, completionHandler: completionHandler) else {
            return
        }
        
        var images: [NewtManager.Image] = []
        
        // Decode CBOR response
        let imagesCbor = cbor["images"]
        for imageCbor in imagesCbor.arrayValue {
            let slot = imageCbor["slot"].intValue
            let version = imageCbor["version"].stringValue
            let confirmed = imageCbor["confirmed"].boolValue
            let pending = imageCbor["pending"].boolValue
            let active = imageCbor["active"].boolValue
            let bootable = imageCbor["bootable"].boolValue
            let hash = imageCbor["hash"].dataValue
            
            let image = NewtManager.Image(slot: slot, version: version, isConfirmed: confirmed, isPending: pending, isActive: active, isBootable: bootable, hash: hash)
            images.append(image)
        }
        
        completionHandler?(images, nil)
    }
    
    // MARK: Echo
    private func parseEcho(cbor: CBOR) {
        defer {
            newtRequestsQueue.next()
        }
        
        let completionHandler = newtRequestsQueue.first()?.completion
        guard NewtManager.verifyResponseCode(cbor: cbor, completionHandler: completionHandler) else {
            return
        }
        
        let echoResponse = cbor["r"].stringValue
        completionHandler?(echoResponse, nil)
    }
    
    // MARK: TaskStats
    private func parseResponseTaskStats(cbor: CBOR) {
        defer {
            newtRequestsQueue.next()
        }
        
        let completionHandler = newtRequestsQueue.first()?.completion
        guard NewtManager.verifyResponseCode(cbor: cbor, completionHandler: completionHandler) else {
            return
        }
        
        var taskStats: [NewtManager.TaskStats] = []
        for (key, value) in cbor["tasks"].dictionaryValue {
            
            let name = key.stringValue
            let state = value["state"].uIntValue
            let runTime = value["runtime"].uIntValue
            let priority = value["prio"].uIntValue
            let taskId = value["tid"].uIntValue
            let contextSwichCount = value["cswcnt"].uIntValue
            let stackUsed = value["stkuse"].uIntValue
            let stackSize = value["stksiz"].uIntValue
            let lastSanityCheckin = value["last_checkin"].uIntValue
            let nextSanityCheckin = value["next_checkin"].uIntValue
            
            let taskStat = NewtManager.TaskStats(taskId: taskId, name: name, priority: priority, state: state, runTime: runTime, contextSwichCount: contextSwichCount, stackSize: stackSize, stackUsed: stackUsed, lastSanityCheckin: lastSanityCheckin, nextSanityCheckin: nextSanityCheckin)
            taskStats.append(taskStat)
        }
        
        completionHandler?(taskStats, nil)
    }
    
    // MARK: Stats
    private func parseResponseStats(cbor: CBOR) {
        defer {
            newtRequestsQueue.next()
        }
        
        let completionHandler = newtRequestsQueue.first()?.completion
        guard NewtManager.verifyResponseCode(cbor: cbor, completionHandler: completionHandler) else {
            return
        }
        
        let stats = cbor["stat_list"].arrayValue.map({$0.stringValue})
        completionHandler?(stats, nil)
    }
    
    // MARK: StatDetails
    private func parseResponseStatDetails(cbor: CBOR) {
        defer {
            newtRequestsQueue.next()
        }
        
        let completionHandler = newtRequestsQueue.first()?.completion
        guard NewtManager.verifyResponseCode(cbor: cbor, completionHandler: completionHandler) else {
            return
        }
        
        var stats: [NewtManager.StatDetails] = []
        for (key, value) in cbor["fields"].dictionaryValue {
            let statName = key.stringValue
            let statValue = value.uIntValue
            
            let statDetails = NewtManager.StatDetails(name: statName, value: statValue)
            stats.append(statDetails)
        }
        completionHandler?(stats, nil)
    }
    
    // MARK: Basic Command
    private func parseBasicResponse(cbor: CBOR) {
        defer {
            newtRequestsQueue.next()
        }
        
        let completionHandler = newtRequestsQueue.first()?.completion
        guard NewtManager.verifyResponseCode(cbor: cbor, completionHandler: completionHandler) else {
            return
        }
        
        completionHandler?(nil, nil)
    }
    
    // MARK: Upload Image
    
    private func parseResponseUploadImage(cbor: CBOR, imageData: Data) {
        let request = newtRequestsQueue.first()
        
        guard NewtManager.verifyResponseCode(cbor: cbor, completionHandler: request?.completion) else {
            newtRequestsQueue.next()
            return
        }
        
        let offset = cbor["off"].intValue
        if let writeData = newtUploadPacketData(from: imageData, offset: offset, progress: request?.progress, completion: request?.completion) {
            
            let requestPacketData = NewtManager.Request.uploadPacket.encode(data: writeData)
            
            DLog("Send Command: Op:\(NewtManager.Request.uploadPacket.op.rawValue) Flags:\(NewtManager.Request.uploadPacket.flags.rawValue) Len:\(writeData.count) Group:\(NewtManager.Request.uploadPacket.group.rawValue) Seq:\(NewtManager.Request.uploadPacket.seq) Id:\(NewtManager.Request.uploadPacket.id) Data:[\(hexDescription(data: writeData))]")
                        
            delegate?.onNewtWrite(data: requestPacketData) { [weak self] (_, error) in
                if error != nil {
                    request?.completion?(nil, error)
                    self?.newtRequestsQueue.next()
                }
            }
            
        }
    }
    
    private func responseError(error: Error?) {
        defer {
            newtRequestsQueue.next()
        }
        
        newtResponseCache.removeAll()
        
        let completionHandler = newtRequestsQueue.first()?.completion
        completionHandler?(nil, error)
    }
    
    
    // MARK: - Utils
    static func verifyResponseCode(cbor: CBOR, isMandatory: Bool = false, completionHandler: RequestCompletionHandler?) -> Bool {
        
        guard let returnCodeRaw = cbor["rc"].uInt16 else {
            if isMandatory {
                DLog("parseResponse Error: rc not found")
                completionHandler?(nil, NewtError.receivedResponseMissingFields)
            }
            return !isMandatory
        }
        
        guard let returnCode = Packet.ReturnCode(rawValue: returnCodeRaw) else {
            if isMandatory {
                DLog("parseResponse Error: rc invalid value")
                completionHandler?(nil, NewtError.receviedResponseInvalidValues)
            }
            return isMandatory
        }
        
        guard returnCode == .ok else {
            DLog("parseResponse Error: \(returnCode.description)")
            completionHandler?(nil, NewtError.receivedResultNotOk(returnCode.description))
            return false
        }
        
        return true
    }
    
    static func newtShowErrorAlert(from controller: UIViewController, title: String? = "Error", error: Error) {
        let message: String?
        if let newtError = error as? NewtError {
            message = newtError.description
        }
        else {
            message = error.localizedDescription
        }
        
        showErrorAlert(from: controller, title: title, message: message)
    }
}

