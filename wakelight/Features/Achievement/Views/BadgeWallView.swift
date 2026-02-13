import SwiftUI

struct BadgeWallView: View {
    @StateObject private var viewModel = BadgeWallViewModel()

    var body: some View {
        NavigationView {
            List {
                ForEach(viewModel.items) { item in
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: item.achievement.iconName)
                            .font(.system(size: 22, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .foregroundColor(item.isUnlocked ? .yellow : .gray)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.achievement.title)
                                .font(.headline)

                            Text(item.achievement.description)
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            ProgressView(value: Double(min(item.progressValue, item.achievement.targetValue)), total: Double(item.achievement.targetValue))

                            Text("\(item.progressValue)/\(item.achievement.targetValue)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if item.isUnlocked {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(.green)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle("Badges")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct BadgeWallView_Previews: PreviewProvider {
    static var previews: some View {
        BadgeWallView()
    }
}
