import Foundation

/// 拾光星图领域事件总线
final class DomainEventBus {
    static let shared = DomainEventBus()
    private init() {}
    
    enum Event {
        /// 显影完成事件：用户完成写话/沉淀，该访次正式升级为故事节点
        /// placeClusterIds: 涉及到的地点（单点加入时只有 1 个；跨地点合并时会有多个）
        case storySettled(visitLayerId: UUID, placeClusterIds: [UUID])
        /// 地点解锁事件
        case locationUnlocked(placeClusterId: UUID)
    }
    
    // 简单的通知中心实现，后续可扩展为更强大的 Combine 发射器
    func emit(_ event: Event) {
        NotificationCenter.default.post(name: .wakelightDomainEvent, object: event)
    }
}

extension Notification.Name {
    static let wakelightDomainEvent = Notification.Name("wakelightDomainEvent")
}
