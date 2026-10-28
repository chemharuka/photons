import AppKit
import PhotonsCatalog

/// 右键菜单里「加入相册 ▸ / 移出相册 ▸」的查询与写入，三个面共用（网格、胶片条、左栏照片列表）。
///
/// 这一层存在的原因很具体：三个视图各有一个 `AssetContextMenu` 实例（各自是那个人口的家），
/// 但「相册清单长什么样」「点一下往库里写什么」必须只有一份实现 —— 否则网格和胶片条会在同一个
/// 右键菜单上做出不同的两件事，而那种不一致只有在用户手里才看得见。
@MainActor
enum AlbumMenuSupport {

    /// 菜单要列出的相册，带「选中的照片是否已全在里面」。
    static func items(session: CatalogSession?, ids: [String]) -> [AssetContextMenu.AlbumItem] {
        guard let session, !ids.isEmpty else { return [] }
        return AssetContextMenu.albumItems(albums: session.albums,
                                           memberships: session.albumMemberships(of: ids),
                                           selectedIDs: ids)
    }

    /// 一次点击 = 一次事务（`Catalog.addAssets` 内部一个 `dbQueue.write`）。
    ///
    /// 这里吞掉错误是**有意的**：菜单动作没有可以承接错误的界面，而唯一现实的失败是"这一行相册
    /// 已经被删了"——那时正确的表现是菜单下次打开时不再列出它，不是弹一个对话框。库状态的真相
    /// 仍在 `album_assets` 里，左栏下一次 `reload()` 就会说实话。
    static func add(_ ids: [String], albumID: String, session: CatalogSession?) {
        guard let session, !ids.isEmpty else { return }
        _ = try? session.addPhotos(ids, toAlbum: albumID)
    }

    static func remove(_ ids: [String], albumID: String, session: CatalogSession?) {
        guard let session, !ids.isEmpty else { return }
        _ = try? session.removePhotos(ids, fromAlbum: albumID)
    }
}
