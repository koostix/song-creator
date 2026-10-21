import AVFoundation
import AppKit
import AudioToolbox.AUCocoaUIView
import CoreAudioKit

struct PluginInfo: Identifiable, Hashable {
    let name: String
    let manufacturer: String
    let type: UInt32
    let subType: UInt32
    let manufacturerCode: UInt32
    var id: String { "\(type)-\(subType)-\(manufacturerCode)" }

    func makeSlot() -> PluginSlot {
        PluginSlot(name: name, manufacturer: manufacturer, type: type, subType: subType, manufacturerCode: manufacturerCode)
    }
}

/// Installed Audio Units, grouped by manufacturer.
enum PluginCatalog {
    private static var cache: [UInt32: [PluginInfo]] = [:]

    static func list(_ types: [UInt32]) -> [PluginInfo] {
        types.flatMap { type -> [PluginInfo] in
            if let c = cache[type] { return c }
            let desc = AudioComponentDescription(componentType: type, componentSubType: 0,
                                                 componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
            let found = AVAudioUnitComponentManager.shared().components(matching: desc).map { c in
                PluginInfo(name: c.name, manufacturer: c.manufacturerName, type: c.audioComponentDescription.componentType,
                           subType: c.audioComponentDescription.componentSubType,
                           manufacturerCode: c.audioComponentDescription.componentManufacturer)
            }
            cache[type] = found
            return found
        }
        .sorted { ($0.manufacturer.lowercased(), $0.name.lowercased()) < ($1.manufacturer.lowercased(), $1.name.lowercased()) }
    }

    static var effects: [PluginInfo] { list([kAudioUnitType_Effect, kAudioUnitType_MusicEffect]) }
    static var instruments: [PluginInfo] { list([kAudioUnitType_MusicDevice]) }

    static func grouped(_ list: [PluginInfo]) -> [(String, [PluginInfo])] {
        Dictionary(grouping: list, by: \.manufacturer)
            .map { ($0.key, $0.value) }
            .sorted { $0.0.lowercased() < $1.0.lowercased() }
    }

    static func refresh() { cache = [:] }
}

/// One floating editor window per plugin slot.
enum PluginWindows {
    private static var windows: [UUID: NSWindow] = [:]

    static func open(_ unit: AVAudioUnit, slot: UUID, title: String) {
        if let w = windows[slot] {
            w.makeKeyAndOrderFront(nil)
            return
        }
        unit.auAudioUnit.requestViewController { vc in
            DispatchQueue.main.async {
                let window: NSWindow
                if let vc {
                    var size = vc.preferredContentSize
                    if size.width < 50 || size.height < 50 { size = vc.view.frame.size }
                    if size.width < 50 || size.height < 50 { size = NSSize(width: 600, height: 400) }
                    window = makeWindow(size: size, title: title)
                    window.contentViewController = vc
                    window.setContentSize(size)
                } else {
                    let view = cocoaView(unit) ?? genericView(unit)
                    window = makeWindow(size: view.frame.size, title: title)
                    window.contentView = view
                }
                window.center()
                window.makeKeyAndOrderFront(nil)
                windows[slot] = window
            }
        }
    }

    static func closeAll() {
        for w in windows.values { w.close() }
        windows = [:]
    }

    static func close(_ slot: UUID) {
        windows[slot]?.close()
        windows[slot] = nil
    }

    private static func makeWindow(size: NSSize, title: String) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.level = .floating
        return w
    }

    /// Classic (v2) plugins publish a Cocoa view factory.
    private static func cocoaView(_ unit: AVAudioUnit) -> NSView? {
        let au = unit.audioUnit
        var size: UInt32 = 0
        var writable: DarwinBoolean = false
        guard AudioUnitGetPropertyInfo(au, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &size, &writable) == noErr,
              size > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioUnitCocoaViewInfo>.alignment)
        defer { raw.deallocate() }
        guard AudioUnitGetProperty(au, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, raw, &size) == noErr else { return nil }
        let info = raw.assumingMemoryBound(to: AudioUnitCocoaViewInfo.self).pointee
        let bundleURL = info.mCocoaAUViewBundleLocation.takeRetainedValue() as URL
        let className = info.mCocoaAUViewClass.takeRetainedValue() as String
        guard let bundle = Bundle(url: bundleURL), bundle.load(),
              let cls = bundle.classNamed(className) as? NSObject.Type,
              let factory = cls.init() as? AUCocoaUIBase else { return nil }
        return factory.uiView(forAudioUnit: au, with: NSSize(width: 500, height: 350))
    }

    private static func genericView(_ unit: AVAudioUnit) -> NSView {
        let v = AUGenericView(audioUnit: unit.audioUnit)
        v.showsExpertParameters = true
        if v.frame.width < 50 { v.setFrameSize(NSSize(width: 420, height: 300)) }
        return v
    }
}
