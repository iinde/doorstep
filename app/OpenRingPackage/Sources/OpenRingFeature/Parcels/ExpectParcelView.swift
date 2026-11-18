import SwiftUI

/// "I'm expecting a parcel": tracking number in, Doorstep does the rest.
public struct ExpectParcelView: View {
    let onDone: () -> Void

    @State private var tracking = ""
    @State private var shop = ""
    @State private var carrier: Carrier?
    @State private var knowsDay = false
    @State private var day = Date()
    @ObservedObject private var tracker = Tracker.shared
    @FocusState private var focused: Bool

    public init(onDone: @escaping () -> Void) { self.onDone = onDone }

    private var number: String {
        tracking.uppercased().replacingOccurrences(of: " ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the number's shape says, when you haven't picked.
    private var detected: Carrier? {
        guard !number.isEmpty else { return nil }
        return Carrier.distinctiveShapes.first { number.range(of: $0.1, options: .regularExpression) != nil }?.0
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                DoorstepMark(size: 22)
                Text("I'm expecting a parcel").font(DS.title).foregroundStyle(DS.paper)
            }
            .padding(.bottom, 6)
            Text("Doorstep keeps track, reminds you on the day, and shows you the door when it arrives.")
                .font(DS.body).foregroundStyle(DS.ash)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 20)

            label("Tracking number")
            TextField("e.g. AB123456789GB", text: $tracking)
                .textFieldStyle(.plain)
                .font(DS.monoBody)
                .foregroundStyle(DS.paper)
                .focused($focused)
                .padding(.horizontal, 12).frame(height: 36)
                .background(DS.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack(spacing: 6) {
                if let d = carrier ?? detected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.porchlight)
                    Text(carrier == nil ? "Looks like \(d.rawValue)" : d.rawValue)
                } else if !number.isEmpty {
                    Text("Pick the carrier if you know it")
                } else {
                    Text("Optional")
                }
                Spacer()
                Menu(carrier?.rawValue ?? "Carrier") {
                    Button("Work it out") { carrier = nil }
                    Divider()
                    ForEach(Carrier.allCases) { c in Button(c.rawValue) { carrier = c } }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .font(DS.meta).foregroundStyle(DS.ash)
            .padding(.top, 6).padding(.bottom, 16)

            label("From (optional)")
            TextField("e.g. ASOS", text: $shop)
                .textFieldStyle(.plain)
                .font(DS.body)
                .foregroundStyle(DS.paper)
                .padding(.horizontal, 12).frame(height: 36)
                .background(DS.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.bottom, 16)

            Toggle(isOn: $knowsDay.animation(DS.settle)) {
                Text("I know which day it's coming").font(DS.body).foregroundStyle(DS.paper)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            if knowsDay {
                DatePicker("", selection: $day, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .padding(.top, 8)
            }

            Text(tracker.hasKey
                 ? "Live tracking is on: Doorstep checks the carrier every 30 minutes."
                 : "For live status inside Doorstep, add a free 17TRACK key in Settings › Parcels. Without it, use Track to open the carrier's page.")
                .font(DS.meta).foregroundStyle(DS.ash)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)

            HStack {
                Spacer()
                Button("Cancel", action: onDone)
                    .keyboardShortcut(.cancelAction)
                Button {
                    ParcelStore.shared.expect(tracking: number, carrier: carrier ?? detected, shop: shop,
                                              expected: knowsDay ? day : nil)
                    Task { await Tracker.shared.checkAll(force: true) }
                    onDone()
                } label: {
                    Text("Expect it").font(DS.bodyStrong)
                        .foregroundStyle(canAdd ? DS.night : DS.ash)
                        .padding(.horizontal, 18).frame(height: 32)
                        .background(canAdd ? DS.porchlight : DS.well, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canAdd)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 420)
        .background(Backdrop())
        .task {
            focused = true
            await tracker.refreshKeyState()
        }
    }

    private var canAdd: Bool { !number.isEmpty || !shop.trimmingCharacters(in: .whitespaces).isEmpty || knowsDay }

    private func label(_ s: String) -> some View {
        Text(s).font(DS.meta).foregroundStyle(DS.ash).padding(.bottom, 6)
    }
}
