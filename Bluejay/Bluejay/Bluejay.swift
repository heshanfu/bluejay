//
//  Bluejay.swift
//  Bluejay
//
//  Created by Jeremy Chiang on 2017-01-03.
//  Copyright © 2017 Steamclock Software. All rights reserved.
//

import Foundation
import CoreBluetooth
import SwiftyUserDefaults

private var standardConnectOptions: [String : AnyObject] = [
    CBConnectPeripheralOptionNotifyOnDisconnectionKey: true as AnyObject,
    CBConnectPeripheralOptionNotifyOnConnectionKey: true as AnyObject
]

/**
 Bluejay is a simple wrapper around CoreBluetooth that focuses on making a common usage case as striaghtforward as possible: a single 'paired' peripheral that the user is interacting with regularly (think most personal electronics devices that have an associated iPhone app: fitness trackers, etc).
 
 It also supports a few other niceties for simplifying usage, including automatic discovery of characteristics as they are used, as well as supporting a background task mode where the interaction with the device can be written as synchronous calls running on a background thread to avoid callback pyramids of death, or heavily chained promises.
 */
public class Bluejay: NSObject {
    
    public static let shared = Bluejay()
    
    // Initializes logging.
    private let logger = BluejayLogger.shared
    
    // MARK: - Private Properties
    
    /// Internal reference to CoreBluetooth's CBCentralManager.
    fileprivate var cbCentralManager: CBCentralManager!
    
    /// List of weak references to objects interested in receiving Bluejay's Bluetooth event callbacks.
    fileprivate var observers: [WeakBluejayEventsObservable] = []
    
    /// Reference to a peripheral that is still connecting. If this is nil, then the peripheral should either be disconnected or connected. This is used to help determine the state of the peripheral's connection.
    fileprivate var connectingPeripheral: BluejayPeripheral?
    
    /// Reference to a peripheral that is connected. If this is nil, then the peripheral should either be disconnected or still connecting. This is used to help determine the state of the peripheral's connection.
    fileprivate var connectedPeripheral: BluejayPeripheral?
    
    /// Internal state allowing or disallowing reconnection attempts upon a disconnection. It should always be set to true, unless there is a manual and explicit disconnection request that is not caused by an error.
    fileprivate var shouldAutoReconnect = true
    
    /// The callback triggered at the end of connection related tasks, such as scanning, connecting, and disconnecting.
    fileprivate var connectionCallback: ((BluejayConnectionResult) -> Void)?
    
    fileprivate var startupBackgroundTask: UIBackgroundTaskIdentifier = UIBackgroundTaskInvalid
    fileprivate var peripheralIdentifierToRestore: PeripheralIdentifier?
    fileprivate var listenRestorable: WeakListenRestorable?
    fileprivate var shouldRestoreState = false
    
    // MARK: - Public Properties
    
    /// Allows checking whether the device's Bluetooth is powered on.
    public var isBluetoothAvailable: Bool {
        return cbCentralManager.state == .poweredOn
    }
    
    /// Allows checking whether Bluejay is currently connecting to a peripheral.
    public var isConnecting: Bool {
        return connectingPeripheral != nil
    }
    
    /// Allows checking whether Bluejay is currently connected to a peripheral.
    public var isConnected: Bool {
        return connectedPeripheral != nil
    }
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        
        shouldRestoreState = UIApplication.shared.applicationState == .background
        
        if shouldRestoreState {
            log.debug("Begin startup background task for restoring CoreBluetooth.")
            startupBackgroundTask = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
        }
    }
    
    public func powerOn(withObserver observer: BluejayEventsObservable, andListenRestorable restorable: ListenRestorable) {
        register(observer: observer)
        listenRestorable = WeakListenRestorable(weakReference: restorable)
        
        cbCentralManager = CBCentralManager(
            delegate: self,
            queue: DispatchQueue.main,
            options: [
                CBCentralManagerOptionShowPowerAlertKey: false,
                CBCentralManagerOptionRestoreIdentifierKey: "Bluejay"
            ]
        )
    }
    
    public func clearLog() {
        logger.clearLog()
    }
    
    // MARK: - Events Registration
    
    public func register(observer: BluejayEventsObservable) {
        observers = observers.filter { $0.weakReference != nil && $0.weakReference !== observer }
        observers.append(WeakBluejayEventsObservable(weakReference: observer))
        
        if cbCentralManager == nil {
            observer.bluetoothAvailable(false)
        }
        else {
            observer.bluetoothAvailable(cbCentralManager.state == .poweredOn)
        }
        
        if let connectedPeripheral = connectedPeripheral {
            observer.connected(connectedPeripheral)
        }
    }
    
    public func unregister(_ observer: BluejayEventsObservable) {
        observers = observers.filter { $0.weakReference != nil && $0.weakReference !== observer }
    }
    
    // MARK: - Scanning
    
    /// Start a scan for peripherals with the specified service, and Bluejay will attempt to connect to the peripheral once it is found.
    public func scan(service serviceIdentifier: ServiceIdentifier, completion: @escaping (BluejayConnectionResult) -> Void) {
        precondition(connectionCallback == nil, "Cannot have more than one active scan or connect request.")
        
        log.debug("Starting scan.")
        
        connectionCallback = completion
        
        cbCentralManager.scanForPeripherals(withServices: [serviceIdentifier.uuid], options: [CBCentralManagerScanOptionAllowDuplicatesKey : false])
    }
    
    /// Cancel oustanding peripheral scans.
    public func cancelScan() {
        log.debug("Cancelling scan.")
        
        cbCentralManager.stopScan()
    }
    
    // MARK: - Connection
    
    public func cancelAllConnections() {
        log.debug("Cancelling all connections.")
        
        let connected = connectedPeripheral
        let connecting = connectedPeripheral
        
        self.connectingPeripheral = nil
        self.connectedPeripheral = nil
        
        connected?.cancelAllOperations(BluejayError.unexpectedDisconnectError())
        connecting?.cancelAllOperations(BluejayError.unexpectedDisconnectError())
        
        connectionCallback?(.failure(BluejayError.unexpectedDisconnectError()))
        connectionCallback = nil
        
        for observer in observers {
            observer.weakReference?.disconected()
        }
    }
    
    /// Attempt to connect directly to a known peripheral.
    public func connect(_ peripheralIdentifier: PeripheralIdentifier, completion: @escaping (BluejayConnectionResult) -> Void) {
        precondition(connectionCallback == nil, "Cannot have more than one active scan or connect request.")
        
        // Block a connect request when restoring, restore should result in the peripheral being automatically connected.
        if (shouldRestoreState) {
            // Cache requested connect, in case restore messes up unexpectedly.
            peripheralIdentifierToRestore = peripheralIdentifier
            return
        }
        
        if let cbPeripheral = cbCentralManager.retrievePeripherals(withIdentifiers: [peripheralIdentifier.uuid]).first {
            log.debug("Found peripheral: \(cbPeripheral.name ?? cbPeripheral.identifier.uuidString), in state: \(cbPeripheral.state.string())")
            
            connectionCallback = completion
            connectingPeripheral = BluejayPeripheral(cbPeripheral: cbPeripheral)
            cbCentralManager.connect(cbPeripheral, options: standardConnectOptions)
            
            log.debug("Issuing connect request to: \(cbPeripheral.name ?? cbPeripheral.identifier.uuidString)")
        }
        else {
            completion(.failure(BluejayError.unknownPeripheralError(peripheralIdentifier)))
        }
    }
    
    /// Disconnect the currently connected peripheral.
    public func disconnect() {
        if let peripheralToDisconnect = connectedPeripheral {
            log.debug("Disconnecting from: \(peripheralToDisconnect.name ?? peripheralToDisconnect.cbPeripheral.identifier.uuidString).")
            
            shouldAutoReconnect = false
            connectionCallback = nil
            
            peripheralToDisconnect.cancelAllOperations(BluejayError.cancelledError())
            cbCentralManager.cancelPeripheralConnection(peripheralToDisconnect.cbPeripheral)
        }
        else {
            log.debug("Cannot disconnect: there is no connected peripheral.")
        }
    }
    
    // MARK: - Actions
    
    /// Read from a specified characteristic.
    public func read<R: BluejayReceivable>(from characteristicIdentifier: CharacteristicIdentifier, completion: @escaping (BluejayReadResult<R>) -> Void) {
        if let peripheral = connectedPeripheral {
            peripheral.read(from: characteristicIdentifier, completion: completion)
        }
        else {
            log.debug("Could not read characteristic \(characteristicIdentifier.uuid.uuidString): Peripheral is not connected.")
            completion(.failure(BluejayError.notConnectedError()))
        }
    }
    
    /// Write to a specified characteristic.
    public func write<S: BluejaySendable>(to characteristicIdentifier: CharacteristicIdentifier, value: S, completion: @escaping (BluejayWriteResult) -> Void) {
        if let peripheral = connectedPeripheral {
            peripheral.write(to: characteristicIdentifier, value: value, completion: completion)
        }
        else {
            log.debug("Could not write to characteristic \(characteristicIdentifier.uuid.uuidString): Peripheral is not connected.")
            completion(.failure(BluejayError.notConnectedError()))
        }
    }
    
    /// Listen for notifications on a specified characteristic.
    public func listen<R: BluejayReceivable>(to characteristicIdentifier: CharacteristicIdentifier, completion: @escaping (BluejayReadResult<R>) -> Void) {
        if let peripheral = connectedPeripheral {
            peripheral.listen(to: characteristicIdentifier, completion: completion)
        }
        else {
            log.debug("Could not listen to characteristic \(characteristicIdentifier.uuid.uuidString): Peripheral is not connected.")
            completion(.failure(BluejayError.notConnectedError()))
        }
    }
    
    /// Cancel listening on a specified characteristic.
    public func cancelListen(to characteristicIdentifier: CharacteristicIdentifier, completion: ((BluejayWriteResult) -> Void)? = nil) {
        if let peripheral = connectedPeripheral {
            peripheral.cancelListen(to: characteristicIdentifier, sendFailure: true, completion: completion)
        }
        else {
            log.debug("Could not cancel listen to characteristic \(characteristicIdentifier.uuid.uuidString): Peripheral is not connected.")
            completion?(.failure(BluejayError.notConnectedError()))
        }
    }
    
    /// Restore a (beleived to be) active listening session, so if we start up in response to a notification, we can receivie it.
    public func restoreListen<R: BluejayReceivable>(to characteristicIdentifier: CharacteristicIdentifier, completion: @escaping (BluejayReadResult<R>) -> Void) {
        if let peripheral = connectedPeripheral {
            peripheral.restoreListen(to: characteristicIdentifier, completion: completion)
        }
        else {
            log.debug("Could not restore listen to characteristic \(characteristicIdentifier.uuid.uuidString): Peripheral is not connected.")
            completion(.failure(BluejayError.notConnectedError()))
        }
    }
    
    /**
     Run a background task using a syncrounous interface to the Bluetooth device.
     
     - Warning
     Be careful not to access anything that is not thread safe from the background task callbacks.
     */
    public func runTask<Params, Result>(
        _ params: Params,
        backgroundThread: @escaping (BluejaySyncPeripheral, Params) throws -> Result,
        mainThread: @escaping (BluejayReadResult<Result>) -> Void)
    {
        if let peripheral = connectedPeripheral {
            DispatchQueue.global().async {
                do {
                    let result = try backgroundThread(BluejaySyncPeripheral(parent: peripheral), params)
                    
                    DispatchQueue.main.async {
                        mainThread(.success(result))
                    }
                }
                catch let error as NSError {
                    DispatchQueue.main.async {
                        mainThread(.failure(error))
                    }
                }
            }
        }
        else {
            mainThread(.failure(BluejayError.notConnectedError()))
        }
    }
    
}

// MARK: - CBCentralManagerDelegate

extension Bluejay: CBCentralManagerDelegate {
    
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log.debug("State updated: \(central.state.string())")
        
        if central.state == .poweredOn && connectedPeripheral != nil {
            attemptListenRestoration()
        }
        
        let backgroundTask = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
        
        if central.state == .poweredOff {
            if let connectingPeripheral = connectingPeripheral {
                cbCentralManager.cancelPeripheralConnection(connectingPeripheral.cbPeripheral)
            }
            
            if let connectedPeripheral = connectedPeripheral {
                cbCentralManager.cancelPeripheralConnection(connectedPeripheral.cbPeripheral)
            }
            
            cbCentralManager.stopScan()
            
            cancelAllConnections()
        }
        
        for observer in observers {
            observer.weakReference?.bluetoothAvailable(central.state == .poweredOn)
            
            if connectedPeripheral != nil {
                observer.weakReference?.connected(connectedPeripheral!)
            }
            else {
                observer.weakReference?.disconected()
            }
        }
        
        UIApplication.shared.endBackgroundTask(backgroundTask)
    }
    
    private func attemptListenRestoration() {
        log.debug("Starting listen restoration.")
        
        let cachedListens = Defaults[.listeningCharacteristics]
        
        if cachedListens.isEmpty {
            log.debug("Listen restoration finished: nothing to restore.")
            return
        }
        
        log.debug("Current cached listens: \(cachedListens)")
        
        for (serviceUuid, characteristicUuid) in cachedListens {
            let serviceIdentifier = ServiceIdentifier(uuid: serviceUuid)
            let characteristicIdentifier = CharacteristicIdentifier(uuid: characteristicUuid as! String, service: serviceIdentifier)
            
            if let listenRestorable = listenRestorable?.weakReference {
                // If true, assume the listen callback is restored.
                if !listenRestorable.didFindRestorableListen(on: characteristicIdentifier) {
                    // If false, cancel the listening.
                    cancelListen(to: characteristicIdentifier)
                }
            }
            else {
                // If there is no listen restorable delegate, cancel all active listening.
                cancelListen(to: characteristicIdentifier)
            }
        }
        
        log.debug("Listen restoration finished.")
    }
    
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        log.debug("Will restore state.")
        
        shouldRestoreState = false
        
        guard
            let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
            let cbPeripheral = peripherals.first
            else {
                // Weird failure case that seems to happen sometime,
                // restoring but don't have a device in the restore list
                // try to trigger a reconnect if we have a stored
                // peripheral
                if let id = peripheralIdentifierToRestore {
                    connect(id, completion: { _ in })
                }
                
                return
        }
        
        let peripheral = BluejayPeripheral(cbPeripheral: cbPeripheral)
        
        precondition(peripherals.count == 1, "Invalid number of peripheral to restore.")
        
        log.debug("Peripheral state to restore: \(cbPeripheral.state.string())")
        
        switch cbPeripheral.state {
        case .connecting:
            precondition(connectedPeripheral == nil,
                         "Connected peripheral is not nil during willRestoreState for state: connecting.")
            connectingPeripheral = peripheral
        case .connected:
            precondition(connectingPeripheral == nil,
                         "Connecting peripheral is not nil during willRestoreState for state: connected.")
            connectedPeripheral = peripheral
        case .disconnecting:
            precondition(connectingPeripheral == nil,
                         "Connecting peripheral is not nil during willRestoreState for state: disconnecting.")
            connectedPeripheral = peripheral
        case .disconnected:
            precondition(connectingPeripheral == nil && connectedPeripheral == nil,
                         "Connecting and connected peripherals are not nil during willRestoreState for state: disconnected.")
        }
        
        log.debug("State restoration finished.")
        
        if startupBackgroundTask != UIBackgroundTaskInvalid {
            log.debug("Cancelling startup background task.")
            
            UIApplication.shared.endBackgroundTask(startupBackgroundTask)
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let backgroundTask =  UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
        
        log.debug("Did connect to: \(peripheral.name ?? peripheral.identifier.uuidString)")
        
        connectedPeripheral = connectingPeripheral
        connectingPeripheral = nil
        
        connectionCallback?(.success(connectedPeripheral!))
        connectionCallback = nil
        
        for observer in observers {
            observer.weakReference?.connected(connectedPeripheral!)
        }
        
        shouldAutoReconnect = true
        
        UIApplication.shared.endBackgroundTask(backgroundTask)
    }
    
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let backgroundTask =  UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
        
        let peripheralString = peripheral.name ?? peripheral.identifier.uuidString
        let errorString = error?.localizedDescription ?? ""
        
        log.debug("Did disconnect from: \(peripheralString) with error: \(errorString)")
        
        if connectingPeripheral == nil && connectedPeripheral == nil {
            log.debug("Disconnection is either bogus or already handled, Bluejay has no connected peripheral.")
            return
        }
        
        cancelAllConnections()
        
        log.debug("Should auto-reconnect: \(self.shouldAutoReconnect)")
        
        if shouldAutoReconnect {
            log.debug("Issuing reconnect to: \(peripheral.name ?? peripheral.identifier.uuidString)")
            
            connect(PeripheralIdentifier(uuid: peripheral.identifier), completion: {_ in })
        }
        
        UIApplication.shared.endBackgroundTask(backgroundTask)
    }
    
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let peripheralString = peripheral.name ?? peripheral.identifier.uuidString
        let errorString = error?.localizedDescription ?? ""
        
        log.debug("Did fail to connect to: \(peripheralString) with error: \(errorString)")
        
        // Use the same clean up logic provided in the did disconnect callback.
        centralManager(central, didDisconnectPeripheral: peripheral, error: error)
    }
    
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let peripheralString = peripheral.name ?? peripheral.identifier.uuidString
        
        log.debug("Did discover: \(peripheralString)")
        log.debug("Connecting to: \(peripheralString)")
        
        cbCentralManager.stopScan()
        connectingPeripheral = BluejayPeripheral(cbPeripheral: peripheral)
        cbCentralManager.connect(peripheral, options: standardConnectOptions)
    }
    
}
