import SwiftUI

struct BuildsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let jobs = model.builds.jobs
        Group {
            if jobs.isEmpty {
                ContentUnavailableView {
                    Label("No builds", systemImage: "hammer")
                } description: {
                    Text("Builds you start from a game or from nxnative's updates show here, with their progress and log.")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(jobs.reversed()) { job in
                            BuildProgressCard(job: job, compact: job.state != .running)
                        }
                        if jobs.contains(where: { !$0.isActive }) {
                            Button("Clear Finished") { model.builds.clearFinished() }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Builds")
    }
}

struct BuildProgressCard: View {
    @Environment(AppModel.self) private var model
    let job: BuildJob
    var compact = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(job.name).font(.headline)
                    stateBadge
                    Spacer()
                    if job.isActive {
                        Button(LocalizedStringKey(job.state == .queued ? "Remove" : "Stop")) { model.builds.cancel(job) }
                    }
                    if let log = job.logURL {
                        Button("Log") { NSWorkspace.shared.open(log) }
                    }
                }
                if job.state == .running {
                    if job.stageN > 0 {
                        Text(LF("Step %lld of %lld: %@", job.stageK, job.stageN, job.stageName)).font(.callout)
                    }
                    if let f = job.fraction {
                        ProgressView(value: f)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    HStack {
                        Text([job.step, job.detail].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        if let c = job.cores {
                            Label(LF("%@ of %lld cores busy", String(format: "%.1f", c), CPULoad.count), systemImage: "cpu").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .help("All of the Mac's processes, sampled every 2 s. Far below the core count: the build waits on one core (a Python step), not on the Mac")
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(timeLine).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                if !job.stages.isEmpty {
                    DisclosureGroup(LF("Steps done: %lld · %@", job.stages.count, BuildStats.duration(job.stages.reduce(0) { $0 + $1.seconds }))) {
                        StageTimesTable(stages: job.stages, total: max(1, job.stages.reduce(0) { $0 + $1.seconds })).padding(.top, 4)
                    }
                    .font(.callout)
                }
                if case .failed(let m) = job.state {
                    Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
                }
                if !compact || job.state == .running {
                    LogView(lines: job.lines)
                        .frame(height: compact ? 120 : 260)
                }
            }
            .padding(6)
        }
    }

    private var timeLine: String {
        let e = Duration.seconds(job.elapsed).formatted(.time(pattern: .hourMinuteSecond))
        if let eta = job.eta, eta > 0 { return LF("%@ elapsed · about %@ left", e, Duration.seconds(eta).formatted(.time(pattern: .hourMinuteSecond))) }
        return LF("%@ elapsed", e)
    }

    @ViewBuilder private var stateBadge: some View {
        switch job.state {
        case .queued: Badge(text: L("Waiting"), color: .secondary)
        case .running: Badge(text: L("Building"), color: .blue)
        case .succeeded: Badge(text: L("Done"), color: .green)
        case .failed: Badge(text: L("Failed"), color: .red)
        case .cancelled: Badge(text: L("Stopped"), color: .secondary)
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("[RED]") ? Color.red : line.hasPrefix("▸") ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(i)
                    }
                }
                .padding(8)
            }
            .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: lines.count) { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
            .onAppear { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
        }
    }
}

/// The running build, at the bottom of the sidebar
struct BuildMiniStatus: View {
    let job: BuildJob

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "hammer.fill").foregroundStyle(.blue)
                Text(job.name).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer()
                if let f = job.fraction { Text(verbatim: "\(Int(f * 100)) %").font(.caption.monospacedDigit()) }
            }
            if let f = job.fraction { ProgressView(value: f).controlSize(.small) } else { ProgressView().progressViewStyle(.linear).controlSize(.small) }
            Text(job.stageName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
