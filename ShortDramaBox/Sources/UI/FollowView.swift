import SwiftUI

/// 记录页的「我的关注」页签：多季合并成一条，新一季单独标出来。
struct FollowListView: View {
    @ObservedObject private var store = FollowStore.shared

    var body: some View {
        Group {
            if store.groups.isEmpty {
                CompatUnavailable("还没有关注", systemImage: "heart",
                                  desc: "在短剧详情页点「关注」，有新一季时会在这里提醒")
            } else {
                List {
                    if store.updateCount > 0 {
                        Section {
                            Label("\(store.updateCount) 部短剧更新了新一季",
                                  systemImage: "bell.badge.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.pink)
                        }
                    }
                    Section {
                        ForEach(store.groups) { group in
                            NavigationLink {
                                destination(for: group)
                            } label: {
                                row(group)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.unfollow(base: group.base)
                                } label: { Label("取消关注", systemImage: "heart.slash") }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func destination(for group: FollowGroup) -> some View {
        if let latest = group.latest {
            DetailView(series: Series(id: latest.id, title: latest.title, cover: latest.cover))
        }
    }

    private func row(_ group: FollowGroup) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: group.cover)) { $0.resizable().aspectRatio(contentMode: .fill) }
                placeholder: { Rectangle().fill(Color.white.opacity(0.1)) }
                .frame(width: 46, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if group.hasUpdate {
                        Text("新一季")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.pink).foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .offset(x: -3, y: -3)
                    }
                }
            VStack(alignment: .leading, spacing: 5) {
                Text(group.displayTitle)
                    .font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(group.seasonSummary)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if group.hasUpdate, let latest = group.latest {
                    Text("\(latest.displayName)已上线")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.pink)
                }
            }
        }
    }
}
