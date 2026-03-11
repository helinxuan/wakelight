import SwiftUI

struct AchievementUnlockToastView: View {
    let achievement: Achievement

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: achievement.iconName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.yellow)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.yellow.opacity(0.15)))

            VStack(alignment: .leading, spacing: 4) {
                Text("成就解锁")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(achievement.title)
                    .font(.headline)

                Text(achievement.description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.15), radius: 12, x: 0, y: 6)
        .padding(.horizontal, 16)
    }
}

#Preview {
    AchievementUnlockToastView(
        achievement: Achievement(
            id: "story_nodes_1",
            title: "初行者",
            description: "完成第 1 次故事沉淀",
            iconName: "sparkles",
            targetValue: 1
        )
    )
}
