import SwiftUI

struct RoomTileView: View {
    let room: RoomSensor
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(room.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if let batt = room.battery {
                    Text("🔋 \(Int(batt))%")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            if let temp = room.temperature {
                Text(String(format: "%.1f°", temp))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(room.temperatureColor.color)
            } else {
                Text("--°")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            if let humid = room.humidity {
                HStack(spacing: 4) {
                    Image(systemName: "humidity")
                        .font(.caption2)
                    Text("\(Int(humid))%")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(in: RoundedRectangle(cornerRadius: 16))
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isSelected ? room.temperatureColor.color : .clear, lineWidth: 2)
        )
        .overlay(alignment: .bottom) {
            room.temperatureColor.color
                .frame(height: 3)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16))
        }
    }
}
