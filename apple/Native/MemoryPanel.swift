import SwiftUI

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
