import SwiftUI
import os

/// Memory numbers used by the model catalog and the settings screen.
enum DeviceMemory {
    /// Physical RAM of the device in bytes.
    static var physical: UInt64 { ProcessInfo.processInfo.physicalMemory }
    /// Bytes this process can still allocate before iOS terminates it.
    /// Reflects the increased-memory-limit entitlement when it is active.
    static var available: UInt64 {
        #if os(iOS) && !targetEnvironment(simulator)
        return UInt64(max(0, os_proc_available_memory()))
        #else
        return physical / 2
        #endif
    }
    /// Memory the app uses right now (physical footprint).
    static var used: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
    /// Total limit iOS applies to this app: what it uses plus what is left.
    static var limit: UInt64 { used + available }
    /// iOS normally allows roughly half of the RAM; well above that means the entitlement is active.
    static var increasedLimitActive: Bool { Double(limit) > Double(physical) * 0.62 }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

struct MemoryPanel: View {
    @State private var tick = 0
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    var body: some View {
        Form {
            Section("ذاكرة الجهاز") {
                LabeledContent("الذاكرة الفعلية", value: DeviceMemory.format(DeviceMemory.physical))
                LabeledContent("الحد المسموح للتطبيق", value: DeviceMemory.format(DeviceMemory.limit))
                LabeledContent("يستخدمه التطبيق الآن", value: DeviceMemory.format(DeviceMemory.used))
                LabeledContent("المتاح الآن", value: DeviceMemory.format(DeviceMemory.available))
            }.id(tick)
            Section("زيادة الذاكرة") {
                Label(DeviceMemory.increasedLimitActive ? "الزيادة مفعّلة" : "الزيادة غير مفعّلة على الأرجح",
                      systemImage: DeviceMemory.increasedLimitActive ? "checkmark.seal" : "exclamationmark.triangle")
                Text("لتفعيلها: أضف «Increased Memory Limit» إلى App ID التطبيق (iloader يضيفها تلقائيا، أو استخدم GetMoreRam)، ثم أعد تثبيت التطبيق. البوابات والنماذج المحلية تستهلك من نفس الحد.")
                    .font(.footnote)
            }
        }
        .navigationTitle("الذاكرة")
        .onReceive(timer) { _ in tick += 1 }
    }
}
