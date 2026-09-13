# ADR 0017: 当前自然日覆盖与成本扫描续跑

- 状态：Accepted
- 日期：2026-09-13
- 补充：[ADR 0003](0003-frozen-cost-scan-generations.md) 和 [ADR 0015](0015-reconciled-today-token-ledger.md)

## 问题

已发布账本只包含历史日期时，按当前日期筛选得到的空集合不能证明 Today 为零。
冻结扫描代可能在午夜前启动、午夜后发布，因此发布时间也不能证明覆盖当前自然日。
此前空账本与零分母相等，会把任务 Today 一起覆盖成零。

另一个独立问题是：展示刷新被策略拒绝之前，或者文件事件被 cadence 限流之前，
刷新入口会取消已有的续跑 timer，导致有界扫描暂停到下一次外部刷新。

## 决定

1. 新增整数元数据 `cost_published_coverage_at_ms`，表示发布代冻结 inventory 的时间；
   `cost_published_at_ms` 仍表示发布时间。发布时在同一事务内写入二者，再清除扫描代。
2. 只有覆盖时间非未来、与请求属于同一本地自然日，且既有 schema、价格、时区校验通过，
   才返回当前周期的完整发布摘要。缺失或过期覆盖返回回填状态，不把空集合当零。
3. 旧缓存不删库、不升级表结构、不强制重扫。既有扫描确认 inventory 与 checkpoints
   完整且无变化时，仅以一个元数据事务推进覆盖时间；同日暖刷新仍为零 JSONL 读取、零写入。
4. 普通 coalesce 请求保留已有续跑截止时间；被拒绝的展示请求不打断续跑。
   显式 replace、关闭周期统计或受限环境仍允许取消。预算耗尽后的续跑优先于合并的待处理请求。
5. HUD 和页脚共用 Today 选择逻辑：完整覆盖的真实零显示 `0`；没有可信数值显示回填状态；
   同一本地日的现有快照可暂估展示，但 help 和辅助功能必须说明尚未与完整父子任务账本对齐。
   Token 完整但价格未知显示“未定价”，不混同“回填中”，也不显示为零费用。
6. ADR 0015 的完整根任务账本对齐不变：所有根桶之和必须等于当天模型桶 Token 总量，
   才允许显示包含子代理的任务值及全机分母。

## 性能与边界

继续使用既有单次 8 MiB / 50 ms CPU / 250 ms wall 预算、5 秒续跑与 5 分钟自动刷新门控。
没有新增扫描器、定时器、网络请求、CLI 依赖或 SwiftUI render 写入。
受限环境下的后台暂停保持原策略。跨日覆盖恢复只有一个小型元数据事务。

## 上游参照

核对 CodexBar 2026-09-13 的 main
[`9ac9499`](https://github.com/steipete/CodexBar/commit/9ac949917d9bb04f92910e666a9a98ec018a9ee4)
（同期 Release v0.60.1）：本地自然日、时区缓存校验、checkpoint 有界续扫，以及
“覆盖建立后才能将缺失日期解释为零”与此决定一致。参照
[CostUsageFetcher](https://github.com/steipete/CodexBar/blob/9ac949917d9bb04f92910e666a9a98ec018a9ee4/Sources/CodexBarCore/CostUsageFetcher.swift#L1212-L1244)。
仅借鉴边界语义，不引入 CodexBar 的运行时依赖。

## 验证

`test-cost-usage-freshness.sh` 覆盖跨日假零、跨午夜冻结代、DST、未来时间、缺失覆盖迁移、
暖刷新零读取/零写入、续跑策略、暂估说明以及未定价费用。它接入完整回归入口。
真实安装版还需核对当前发布日期、父子账本总量与 Today 展示；构建成功不能代替 UI 验收。
