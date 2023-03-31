//
//  ViewModel.swift
//
//  Created by : Tomoaki Yagishita on 2021/09/26
//  © 2021  SmallDeskSoftware
//

import Foundation
import EventKit
import Combine

typealias eventStoreChangeListner = ((_ nofiticaiton: Notification) -> (Void))

public protocol EventKitStoreProtocol: ObservableObject {
    init()
    // authorization
    func updatedAccessStatus() async -> Bool

    // event handling
    func createEvent(_ title: String, startDate: Date, durationInSec: Int, calendarID: String?, alarm: EKAlarm?) async -> EKEvent?
    func eventSyncFromEventKit(_ id: String?) async -> (newStart: Date, newEnd: Date)?
    func events(start: Date, end: Date, calendars:[EKCalendar]?) async -> AsyncStream<EKEvent>
    func getEvent(_ id: String?) async -> EKEvent?
    func updateEventTitle(_ id: String?, newTitle: String) async
    
    // Calendar
    func calendar(for type: EKEntityType) async -> [EKCalendar] // Calendar.calendarIdentifier
    func calendar(_ id: String) async -> EKCalendar?
    func calendarName(_ id: String) async -> String
    func defaultCalendarForNewEvents() async -> EKCalendar?

    // update notification
    func subscribeUpdate(_ subscriber: @escaping () -> ()) async -> AnyCancellable?

    // alarm
    func createRelativeAlarm(_ interval: TimeInterval, sound: String?) -> EKAlarm


    // special for Pomodoro
    func doneEvent(_ eventID:String?, doneDate: Date,_ postFix: String) async
    func cancelEvent(_ eventID:String?, cancelDate: Date) async
}

public actor DummyEventKitStore: EventKitStoreProtocol {
    public init() {}

    public func getEvent(_ id: String?) async -> EKEvent? { return nil }
    public func updateEventTitle(_ id: String?, newTitle: String) async {}

    public func updatedAccessStatus() async -> Bool { return true }
    public func calendarName(_ id: String) async -> String { return "no" }
    public func createEvent(_ title: String, startDate: Date, durationInSec: Int, calendarID: String?, alarm: EKAlarm?) async -> EKEvent? { return nil }
    public func doneEvent(_ eventID: String?, doneDate: Date,_ postFix: String = "") async { return }
    public func cancelEvent(_ eventID: String?, cancelDate: Date) async { return }
    public func eventSyncFromEventKit(_ id: String?) async -> (newStart: Date, newEnd: Date)? { return nil }
    public func events(start: Date, end: Date, calendars:[EKCalendar]?) async -> AsyncStream<EKEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
    public func calendar(for type: EKEntityType) async -> [EKCalendar] { [] }
    public func calendar(_ id: String) async -> EKCalendar? { return nil }
    public func defaultCalendarForNewEvents() async -> EKCalendar? { return nil }

    public func subscribeUpdate(_ subscriber: @escaping () -> ()) async -> AnyCancellable? { return nil }
    nonisolated public func createRelativeAlarm(_ interval: TimeInterval, sound: String? = nil) -> EKAlarm { return EKAlarm() }

}

public actor EventKitStore: EventKitStoreProtocol {
    let store: EKEventStore
    var accessToEvent: Bool = false
    
    public init() {
        store = EKEventStore()

        if EKEventStore.authorizationStatus(for: .event) != .authorized {
        } else {
            self.accessToEvent = true
        }
    }

    public func updatedAccessStatus() async -> Bool {
        do {
            self.accessToEvent = try await store.requestAccess(to: .event)
        } catch {
            print("\(error.localizedDescription)")
            self.accessToEvent = false
        }
        return accessToEvent
    }

    public func calendarName(_ id: String) async -> String {
        guard await updatedAccessStatus() == true else { return ""}
        return self.store.calendar(withIdentifier: id)?.title ?? ""
    }
    
    public func createEvent(_ title: String = "Pomodoro", startDate: Date, durationInSec: Int, calendarID: String? = nil,
                            alarm: EKAlarm? = nil) async -> EKEvent? {
        guard await updatedAccessStatus() == true else { return nil }
        let newEvent = EKEvent(eventStore: self.store)
        newEvent.title = title
        newEvent.startDate = startDate
        newEvent.endDate = newEvent.startDate.advanced(by: Double(durationInSec))
        if let calendarID = calendarID {
            newEvent.calendar = self.store.calendar(withIdentifier: calendarID)
        } else {
            newEvent.calendar = defaultCalendar()
        }
        
        if let alarm = alarm {
            newEvent.addAlarm(alarm)
        }

        do {
            try self.store.save(newEvent, span: .thisEvent, commit: true)
        } catch {
            print("\(error.localizedDescription)")
            return nil
        }
        return newEvent
    }

    public func doneEvent(_ eventID:String?, doneDate: Date,_ postFix: String = "") async {
        guard await updatedAccessStatus() == true else { return }
        guard let eventID = eventID else { return }
        guard let event = await fetchEvent(id: eventID) else { return }
        event.title = event.title + postFix
        event.endDate = doneDate
        event.removeAllAlarm()

        do {
            try self.store.save(event, span: .thisEvent, commit: true)
        } catch {
            print("\(error.localizedDescription)")
        }
    }

    public func cancelEvent(_ eventID:String?, cancelDate: Date) async {
        guard await updatedAccessStatus() == true else { return }
        guard let eventID = eventID else { return }
        guard let event = await fetchEvent(id: eventID) else { return }
        event.title = event.title + "(Cancelled)"
        event.endDate = cancelDate
        event.removeAllAlarm()
        do {
            try self.store.save(event, span: .thisEvent, commit: true)
        } catch {
            print("\(error.localizedDescription)")
        }
    }

    public func events(start: Date, end: Date, calendars:[EKCalendar]?) async -> AsyncStream<EKEvent> {
        guard await updatedAccessStatus() == true else {
            return AsyncStream { _ in }
        }
        return AsyncStream { continuation in
            let predicate = self.store.predicateForEvents(withStart: start, end: end, calendars: calendars)
            self.store.enumerateEvents(matching: predicate) { (event, kmod) in
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
    public func getEvent(_ id: String?) async -> EKEvent? {
        guard await updatedAccessStatus() == true else { return nil }
        guard let id = id else { return nil }
        return store.event(withIdentifier: id)
    }
    
    public func updateEventTitle(_ id: String?, newTitle: String) async {
        guard await updatedAccessStatus() == true else { return }
        guard let event = await getEvent(id) else { return }
        event.title = newTitle
        do {
            try self.store.save(event, span: .thisEvent, commit: true)
        } catch {
            print("\(error.localizedDescription)")
        }

    }
}

extension EventKitStore {
    public func calendar(for type: EKEntityType) async -> [EKCalendar] {
        guard await updatedAccessStatus() == true else { return [] }
        return store.calendars(for: type)
    }

    public func calendar(_ id: String) async -> EKCalendar? {
        guard await updatedAccessStatus() == true else { return nil }
        return store.calendar(withIdentifier: id)
    }

    // note: because dont want to publish store itself, Store will take care of subscription
    public func subscribeUpdate(_ subscriber: @escaping () -> ()) async -> AnyCancellable? {
        return NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: self.store)
            .sink { value in
                subscriber()
            }
    }
    public func defaultCalendarForNewEvents() async -> EKCalendar? {
        return self.store.defaultCalendarForNewEvents
    }
}

// MARK: alarm
extension EventKitStore {
    nonisolated public func createRelativeAlarm(_ interval: TimeInterval, sound: String? = nil) -> EKAlarm{
        let alarm = EKAlarm(relativeOffset: interval)
        #if os(macOS)
        if let sound = sound {
            alarm.soundName = sound
        }
        #endif
        return alarm
    }
}

extension EventKitStore {
    public func eventSyncFromEventKit(_ id: String?) async -> (newStart: Date, newEnd: Date)?{
        guard let id = id else { return nil }
        guard let event = await fetchEvent(id: id) else { return nil }
        guard event.refresh() == true else { return nil }
        return (event.startDate, event.endDate)
    }
}

extension EventKitStore {
    private func fetchEvent(id: String) async -> EKEvent? {
        guard await updatedAccessStatus() == true else { return nil }
        return self.store.event(withIdentifier: id)
    }
    
    private func defaultCalendar() -> EKCalendar {
        return self.store.defaultCalendarForNewEvents ?? EKCalendar(for: .event, eventStore: self.store)
    }
}

extension EKEvent {
    func removeAllAlarm() {
        if let alarms = self.alarms {
            for alarm in alarms {
                self.removeAlarm(alarm)
            }
        }
    }
}

