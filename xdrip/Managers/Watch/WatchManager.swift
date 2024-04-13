//
//  WatchManager.swift
//  xdrip
//
//  Created by Paul Plant on 9/2/24.
//  Copyright © 2024 Johan Degraeve. All rights reserved.
//

import Foundation
import WatchConnectivity
import WidgetKit
import OSLog

final class WatchManager: NSObject, ObservableObject {
    
    // MARK: - private properties
    
    /// a watch connectivity session instance
    private var session: WCSession
    
    /// a BgReadingsAccessor instance
    private var bgReadingsAccessor: BgReadingsAccessor
    
    /// a coreDataManager instance (must be passed from RVC in the initializer)
    private var coreDataManager: CoreDataManager
    
    /// hold the current watch state model
    private var watchState = WatchState()
    
    private var lastForcedComplicationUpdateTimeStamp: Date = .distantPast
    
    /// for logging
    private var log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryWatchManager)
    
    // MARK: - intializer
    
    init(coreDataManager: CoreDataManager, session: WCSession = .default) {
        
        // set coreDataManager and bgReadingsAccessor
        self.coreDataManager = coreDataManager
        self.bgReadingsAccessor = BgReadingsAccessor(coreDataManager: coreDataManager)
        self.session = session
        
        super.init()
        
        if WCSession.isSupported() {
            session.delegate = self
            session.activate()
        }
        
        processWatchState()
        
    }
    
    private func processWatchState() {
        // create two simple arrays to send to the live activiy. One with the bg values in mg/dL and another with the corresponding timestamps
        // this is needed due to the not being able to pass structs that are not codable/hashable
        let hoursOfBgReadingsToSend: Double = 12
        
        let bgReadings = self.bgReadingsAccessor.getLatestBgReadings(limit: nil, fromDate: Date().addingTimeInterval(-3600 * hoursOfBgReadingsToSend), forSensor: nil, ignoreRawData: true, ignoreCalculatedValue: false)
        
        let slopeOrdinal: Int = !bgReadings.isEmpty ? bgReadings[0].slopeOrdinal() : 1
        
        var deltaChangeInMgDl: Double?
        
        // add delta if needed
        if bgReadings.count > 1 {
            deltaChangeInMgDl = bgReadings[0].currentSlope(previousBgReading: bgReadings[1]) * bgReadings[0].timeStamp.timeIntervalSince(bgReadings[1].timeStamp) * 1000;
        }
        
        var bgReadingValues: [Double] = []
        var bgReadingDatesAsDouble: [Double] = []
        
        for bgReading in bgReadings {
            bgReadingValues.append(bgReading.calculatedValue)
            bgReadingDatesAsDouble.append(bgReading.timeStamp.timeIntervalSince1970)
        }
        
        // now process the WatchState
        watchState.bgReadingValues = bgReadingValues
        watchState.bgReadingDatesAsDouble = bgReadingDatesAsDouble
        watchState.isMgDl = UserDefaults.standard.bloodGlucoseUnitIsMgDl
        watchState.slopeOrdinal = slopeOrdinal
        watchState.deltaChangeInMgDl = deltaChangeInMgDl
        watchState.urgentLowLimitInMgDl = UserDefaults.standard.urgentLowMarkValue
        watchState.lowLimitInMgDl = UserDefaults.standard.lowMarkValue
        watchState.highLimitInMgDl = UserDefaults.standard.highMarkValue
        watchState.urgentHighLimitInMgDl = UserDefaults.standard.urgentHighMarkValue
        watchState.activeSensorDescription = UserDefaults.standard.activeSensorDescription
        watchState.isMaster = UserDefaults.standard.isMaster
        watchState.followerDataSourceTypeRawValue = UserDefaults.standard.followerDataSourceType.rawValue
        watchState.followerBackgroundKeepAliveTypeRawValue = UserDefaults.standard.followerBackgroundKeepAliveType.rawValue
        watchState.disableComplications = !UserDefaults.standard.isMaster && UserDefaults.standard.followerBackgroundKeepAliveType == .disabled
        
        if let sensorStartDate = UserDefaults.standard.activeSensorStartDate {
            watchState.sensorAgeInMinutes = Double(Calendar.current.dateComponents([.minute], from: sensorStartDate, to: Date()).minute!)
        } else {
            watchState.sensorAgeInMinutes = 0
        }
        
        watchState.sensorMaxAgeInMinutes = (UserDefaults.standard.activeSensorMaxSensorAgeInDays ?? 0) * 24 * 60
        
        // let's set the state values if we're using a heartbeat
        if let timeStampOfLastHeartBeat = UserDefaults.standard.timeStampOfLastHeartBeat, let secondsUntilHeartBeatDisconnectWarning = UserDefaults.standard.secondsUntilHeartBeatDisconnectWarning {
            watchState.secondsUntilHeartBeatDisconnectWarning = Int(secondsUntilHeartBeatDisconnectWarning)
            watchState.timeStampOfLastHeartBeat = timeStampOfLastHeartBeat
        }
        
        // let's set the follower server connection values if we're using follower mode
        if let timeStampOfLastFollowerConnection = UserDefaults.standard.timeStampOfLastFollowerConnection {
            watchState.secondsUntilFollowerDisconnectWarning = UserDefaults.standard.followerDataSourceType.secondsUntilFollowerDisconnectWarning
            watchState.timeStampOfLastFollowerConnection = timeStampOfLastFollowerConnection
        }
        
        watchState.remainingComplicationUserInfoTransfers = session.remainingComplicationUserInfoTransfers
        
        sendStateToWatch()
    }
    
    func sendStateToWatch() {
        guard session.isPaired else {
            trace("no Watch is paired", log: self.log, category: ConstantsLog.categoryWatchManager, type: .debug)
            return
        }
        
        guard session.isWatchAppInstalled else {
            trace("watch app is not installed", log: self.log, category: ConstantsLog.categoryWatchManager, type: .debug)
            return
        }
        
        guard session.activationState == .activated else {
            let activationStateString = "\(session.activationState)"
            trace("watch session activationState = %{public}@. Reactivating", log: self.log, category: ConstantsLog.categoryWatchManager, type: .error, activationStateString)
            session.activate()
            return
        }
        
        // if the WCSession is reachable it means that Watch app is in the foreground so send the watch state as a message
        // if it's not reachable, then it means it's in the background so send the state as a userInfo
        // if more than x minutes have passed since the last complication update, call transferCurrentComplicationUserInfo to force an update
        // if not, then just send it as a normal priority transferUserInfo which will be queued and sent as soon as the watch app is reachable again (this will help get the app showing data quicker)
        if let userInfo: [String: Any] = watchState.asDictionary {
            if session.isReachable {
                session.sendMessage(["watchState": userInfo], replyHandler: nil, errorHandler: { (error) -> Void in
                    trace("error sending watch state, error = %{public}@", log: self.log, category: ConstantsLog.categoryWatchManager, type: .error, error.localizedDescription)
                })
            } else {
                if lastForcedComplicationUpdateTimeStamp < Date().addingTimeInterval(-ConstantsWidget.forceComplicationRefreshTimeInMinutes), session.isComplicationEnabled {
                    trace("forcing background complication update, remaining complication transfers left today = %{public}@ / 50", log: self.log, category: ConstantsLog.categoryWatchManager, type: .info, session.remainingComplicationUserInfoTransfers.description)
                    
                    session.transferCurrentComplicationUserInfo(["watchState": userInfo])
                    lastForcedComplicationUpdateTimeStamp = .now
                } else {
                    trace("sending background watch state update", log: self.log, category: ConstantsLog.categoryWatchManager, type: .info)
                    
                    session.transferUserInfo(["watchState": userInfo])
                }
            }
        }
    }
    
    
    // MARK: - Public functions
    
    func updateWatchApp() {
        processWatchState()
    }
}


// MARK: - conform to WCSessionDelegate protocol

extension WatchManager: WCSessionDelegate {
    func sessionDidBecomeInactive(_: WCSession) {}
    
    func sessionDidDeactivate(_: WCSession) {
        session = WCSession.default
        session.delegate = self
        session.activate()
    }
    
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
    }
    
    // process any received messages from the watch app
    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        
        // check which type of update the Watch is requesting and call the correct sending function as needed
        if let requestWatchUpdate = message["requestWatchUpdate"] as? String {
            switch requestWatchUpdate {
            case "watchState":
                DispatchQueue.main.async {
                    self.sendStateToWatch()
                }
            default:
                break
            }
        }
    }
    
    func session(_: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {}
    
    func session(_: WCSession, didReceiveMessageData _: Data) {}
    
    func sessionReachabilityDidChange(_ session: WCSession) {
        if session.isReachable {
            DispatchQueue.main.async {
                self.sendStateToWatch()
            }
        }
    }
}
