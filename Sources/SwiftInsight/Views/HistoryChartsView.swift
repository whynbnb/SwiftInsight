import SwiftUI

// MARK: - Lightweight sparkline
//
// 历史图表只需要折线 / 面积，不需要坐标轴、选择与动画。
// 之前使用 Swift Charts：每个刷新周期都会生成一套 ChartContent 显示列表和
// Metal 资源，常驻内存与峰值都明显偏高。这里改用 Canvas 直接绘制路径，
// 视觉与交互保持不变，但不再链接 Charts 框架。

private struct SparkPoint {
    let date: Date
    let value: Double
}

private struct SparkSeries {
    let color: Color
    let fillOpacity: Double
    let points: [SparkPoint]
}

/// 单条或多条折线（含可选面积填充）。x 轴按时间、y 轴按数值线性映射。
private struct SparklineCanvas: View {
    let series: [SparkSeries]
    /// nil = 按数据最大值自动留白
    var yUpperBound: Double? = nil
    var lineWidth: CGFloat = 1.3

    var body: some View {
        Canvas { context, size in
            draw(context: context, size: size)
        }
        .clipped()
        .accessibilityHidden(true)
    }

    private func draw(context: GraphicsContext, size: CGSize) {
        let all = series.flatMap(\.points)
        guard !all.isEmpty, size.width > 1, size.height > 1 else { return }

        let minDate = all.map(\.date).min() ?? Date()
        let maxDate = all.map(\.date).max() ?? minDate
        let maxValue = all.map(\.value).max() ?? 1
        let upper = yUpperBound ?? max(1, maxValue * 1.12)
        let domain = max(0.0001, upper)

        let inset: CGFloat = 1.5
        let plotWidth = max(1, size.width - inset * 2)
        let plotHeight = max(1, size.height - inset * 2)
        let span = maxDate.timeIntervalSince(minDate)

        func project(_ point: SparkPoint) -> CGPoint {
            let xRatio = span > 0 ? point.date.timeIntervalSince(minDate) / span : 0.5
            let yRatio = max(0, min(1, point.value / domain))
            return CGPoint(
                x: inset + plotWidth * CGFloat(xRatio),
                y: inset + plotHeight * (1 - CGFloat(yRatio))
            )
        }

        for item in series where !item.points.isEmpty {
            let points = item.points.map(project)

            if points.count == 1 {
                let radius: CGFloat = 1.5
                let dot = CGRect(
                    x: points[0].x - radius,
                    y: points[0].y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                context.fill(Path(ellipseIn: dot), with: .color(item.color))
                continue
            }

            let line = smoothPath(points)

            if item.fillOpacity > 0 {
                var area = line
                let baseline = size.height - inset
                area.addLine(to: CGPoint(x: points[points.count - 1].x, y: baseline))
                area.addLine(to: CGPoint(x: points[0].x, y: baseline))
                area.closeSubpath()
                context.fill(area, with: .color(item.color.opacity(item.fillOpacity)))
            }

            context.stroke(
                line,
                with: .color(item.color),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
        }
    }

    /// Catmull-Rom 转三次贝塞尔，接近 Swift Charts 的 .catmullRom 平滑效果
    private func smoothPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)

        guard points.count > 2 else {
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            return path
        }

        for index in 0..<(points.count - 1) {
            let p0 = points[max(0, index - 1)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(points.count - 1, index + 2)]
            let c1 = CGPoint(
                x: p1.x + (p2.x - p0.x) / 6,
                y: p1.y + (p2.y - p0.y) / 6
            )
            let c2 = CGPoint(
                x: p2.x - (p3.x - p1.x) / 6,
                y: p2.y - (p3.y - p1.y) / 6
            )
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}

// MARK: - Mini sparkline (system overview)

struct SystemHistoryCharts: View {
    @EnvironmentObject private var monitor: ProcessMonitor

    var body: some View {
        let samples = monitor.systemHistory
        let cpuPoints = samples.map { SparkPoint(date: $0.date, value: $0.cpu) }
        let memoryPoints = samples.map { SparkPoint(date: $0.date, value: $0.memoryPercent) }
        let thirdPoints = samples.map { SparkPoint(date: $0.date, value: $0.thirdPartyCPU) }
        let applePoints = samples.map { SparkPoint(date: $0.date, value: $0.appleCPU) }
        let categoryMax = max(
            samples.map(\.thirdPartyCPU).max() ?? 0,
            samples.map(\.appleCPU).max() ?? 0
        )

        HStack(spacing: 12) {
            chartCard(title: L("chart.cpu"), unit: "%") {
                SparklineCanvas(
                    series: [SparkSeries(
                        color: .accentColor,
                        fillOpacity: 0.12,
                        points: cpuPoints
                    )],
                    yUpperBound: max(100, (samples.map(\.cpu).max() ?? 1) * 1.1)
                )
            }
            .accessibilityLabel(accessibilitySummary(title: L("chart.cpu"), value: String(format: "%.1f%%", samples.last?.cpu ?? 0)))

            chartCard(title: L("chart.memory"), unit: "%") {
                SparklineCanvas(
                    series: [SparkSeries(
                        color: .orange,
                        fillOpacity: 0.12,
                        points: memoryPoints
                    )],
                    yUpperBound: 100
                )
            }
            .accessibilityLabel(accessibilitySummary(title: L("chart.memory"), value: String(format: "%.1f%%", samples.last?.memoryPercent ?? 0)))

            chartCard(title: L("chart.category"), unit: "%", legend: { categoryLegend }) {
                SparklineCanvas(
                    series: [
                        SparkSeries(color: .orange, fillOpacity: 0, points: thirdPoints),
                        SparkSeries(color: .cyan, fillOpacity: 0, points: applePoints),
                    ],
                    yUpperBound: max(1, categoryMax * 1.12)
                )
            }
            .accessibilityLabel(accessibilitySummary(
                title: L("chart.category"),
                value: String(
                    format: "%@ %.1f%% · Apple %.1f%%",
                    L("chart.series.third"),
                    samples.last?.thirdPartyCPU ?? 0,
                    samples.last?.appleCPU ?? 0
                )
            ))

            VStack(alignment: .trailing, spacing: 4) {
                Text(L("chart.history"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Picker("", selection: $monitor.historyWindow) {
                    ForEach(HistoryWindow.allCases) { window in
                        Text(window.displayName).tag(window)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 88)

                if samples.isEmpty {
                    Text(L("chart.collecting"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(String(format: L("chart.points"), samples.count))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 96, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(height: 72)
    }

    private var categoryLegend: some View {
        HStack(spacing: 6) {
            legendDot(color: .orange, title: L("chart.series.third"))
            legendDot(color: .cyan, title: "Apple")
        }
    }

    private func legendDot(color: Color, title: String) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private func accessibilitySummary(title: String, value: String) -> String {
        "\(title) \(value)"
    }

    private func chartCard<Content: View>(
        title: String,
        unit: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        chartCard(title: title, unit: unit, legend: { EmptyView() }, content: content)
    }

    private func chartCard<Legend: View, Content: View>(
        title: String,
        unit: String,
        @ViewBuilder legend: () -> Legend,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                legend()
                Text(unit)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Process history chart (detail)

struct ProcessHistoryChart: View {
    let samples: [MetricSample]
    let window: HistoryWindow
    var vertical: Bool = false

    var body: some View {
        if samples.count < 2 {
            HStack {
                Text(String(format: L("chart.need_samples"), window.displayName))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(height: vertical ? 34 : 56)
        } else if vertical {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("CPU")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f%%", samples.last?.cpu ?? 0))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                }
                cpuChart
                    .frame(height: 34)

                HStack(spacing: 6) {
                    Text(L("metric.memory"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let last = samples.last {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(last.memoryBytes), countStyle: .memory))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                memoryChart
                    .frame(height: 34)
            }
        } else {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CPU")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    cpuChart
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(L("metric.memory"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    memoryChart
                }

                VStack(alignment: .trailing, spacing: 2) {
                    if let last = samples.last {
                        Text(String(format: "%.1f%%", last.cpu))
                            .font(.caption.monospacedDigit().weight(.semibold))
                        Text(ByteCountFormatter.string(fromByteCount: Int64(last.memoryBytes), countStyle: .memory))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(window.displayName)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 64)
            }
            .frame(height: 56)
        }
    }

    private var cpuChart: some View {
        SparklineCanvas(
            series: [SparkSeries(
                color: .accentColor,
                fillOpacity: 0.15,
                points: samples.map { SparkPoint(date: $0.date, value: $0.cpu) }
            )],
            yUpperBound: max(5, (samples.map(\.cpu).max() ?? 1) * 1.15)
        )
    }

    private var memoryChart: some View {
        let points = samples.map {
            SparkPoint(date: $0.date, value: Double($0.memoryBytes) / 1_048_576.0)
        }
        let maxValue = points.map(\.value).max() ?? 1
        return SparklineCanvas(
            series: [SparkSeries(
                color: .orange,
                fillOpacity: 0.15,
                points: points
            )],
            yUpperBound: max(1, maxValue * 1.12)
        )
    }
}
