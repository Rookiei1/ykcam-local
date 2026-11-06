import AVFoundation
import AVKit
import SwiftUI

@main
struct YKCamApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
        .onChange(of: scenePhase) { _, phase in model.sceneChanged(phase) }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.phase {
            case .ready: ReadyView()
            case .running: RunningView()
            }
        }
        .sheet(isPresented: $model.showRecords) { RecordsView() }
    }
}

// MARK: 准备开始

struct ReadyView: View {
    @EnvironmentObject var model: AppModel
    @State private var busy = false
    @State private var editingArea = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("门口摄像头").font(.title2.bold())
                Text("只在这台手机上工作，不连任何服务器。照片和录像都存在手机里。")
                    .foregroundStyle(.secondary)

                Text("后置镜头").font(.subheadline).foregroundStyle(.secondary)
                Picker("后置镜头", selection: $model.lens) {
                    Text("0.5× 超广角（视野最大）").tag(CameraEngine.Lens.ultra)
                    Text("1× 普通").tag(CameraEngine.Lens.wide)
                }
                .pickerStyle(.segmented)

                Button("框检测区域（门的位置）") { editingArea = true }
                    .buttonStyle(.bordered)

                Stepper("灵敏度 \(model.sensitivity)（越高越容易触发）", value: $model.sensitivity, in: 1...10)
                Picker("记录保留", selection: $model.keepDays) {
                    ForEach([3, 7, 15, 30], id: \.self) { Text("\($0) 天").tag($0) }
                }
                .pickerStyle(.menu)
                Toggle("闯入录像也存进相册", isOn: $model.saveIntrusion)

                Button {
                    busy = true
                    Task { await model.start(); busy = false }
                } label: {
                    Text(busy ? "正在打开相机…" : "开始监控").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)

                Button {
                    Task { await model.openRecords() }
                } label: {
                    Text("查看记录").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if !model.errorText.isEmpty { Text(model.errorText).foregroundStyle(.red) }
                if !OwnerAuth.available {
                    Text("这台手机没设锁屏密码，任何人都能停止警报和查看记录。请先到「设置」里设置。")
                        .foregroundStyle(.red)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("1. 手机插上充电器，音量调到最大，后置摄像头对着门。点开始后有 30 秒让你放好、离开。")
                    Text("2. 连按三次侧边按钮打开「引导式访问」，关掉侧边按钮和音量按钮，「触摸」留着（停止警报要用），点「开始」。")
                    Text("3. 有人闯入：拍 3 张照片并录像，没动静 30 秒后停（至少 1 分钟，最长 10 分钟）。")
                    Text("4. 手机被拿起：马上拍照，前置开始录像，拿手机的人的照片立刻存进相册。一直被拿着走：警报 + 喊话，录像每 30 秒存一段进相册。")
                    Text("5. 监控中 App 被切走或锁屏也会响。停止警报、停止监控、查看记录都要面容 ID 或锁屏密码。")
                    Text("6. 手机被拿走时证据也在这台手机上。打开 iCloud 照片，存进相册的录像会自动同步走；再打开「查找我的 iPhone」。")
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .sheet(isPresented: $editingArea) { AreaEditor() }
    }
}

// MARK: 框检测区域

struct AreaEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var rect: [Double] = [0, 0, 1, 1]

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("用手指在画面上拖出门的位置，只有框里有变化才算闯入。换镜头后要重新框。")
                    .font(.footnote).foregroundStyle(.secondary)
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        CameraPreview(session: model.pipe.engine.session)
                        Rectangle()
                            .fill(Color.orange.opacity(0.15))
                            .overlay(Rectangle().stroke(Color.orange, lineWidth: 2))
                            .frame(width: rect[2] * geo.size.width, height: rect[3] * geo.size.height)
                            .offset(x: rect[0] * geo.size.width, y: rect[1] * geo.size.height)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 4).onChanged { value in
                        let w = geo.size.width, h = geo.size.height
                        let x0 = min(max(value.startLocation.x, 0), w) / w
                        let y0 = min(max(value.startLocation.y, 0), h) / h
                        let x1 = min(max(value.location.x, 0), w) / w
                        let y1 = min(max(value.location.y, 0), h) / h
                        rect = [Double(min(x0, x1)), Double(min(y0, y1)), Double(abs(x1 - x0)), Double(abs(y1 - y0))]
                    })
                }
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                HStack {
                    Button("整个画面") { rect = [0, 0, 1, 1] }.buttonStyle(.bordered)
                    Button("保存") {
                        if rect[2] >= 0.02 && rect[3] >= 0.02 { model.roi = rect }
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationTitle("检测区域")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            rect = model.roi
            await model.openCameraForSetup()
        }
        .onDisappear { model.closeCameraAfterSetup() }
    }
}

// MARK: 监控中：黑屏 + 一行暗字（每分钟换位置防烧屏），点一下看 15 秒预览

struct RunningView: View {
    @EnvironmentObject var model: AppModel
    @State private var spot = CGPoint(x: 170, y: 80)
    @State private var peek = false
    @State private var hideTask: Task<Void, Never>?
    let move = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black
                VolumeHolder().frame(width: 1, height: 1).opacity(0.01)   // 警报时把音量推到最大要用
                Text(model.statusText)
                    .font(.footnote)
                    .foregroundStyle(Color(white: 0.28))
                    .frame(maxWidth: 300)
                    .position(x: min(spot.x, geo.size.width - 150), y: spot.y)
                if peek {
                    VStack(spacing: 12) {
                        CameraPreview(session: model.pipe.engine.session)
                            .aspectRatio(9.0 / 16.0, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        Text(model.statusText).font(.footnote).foregroundStyle(.secondary)
                        Button("停止监控（要验证机主）", role: .destructive) {
                            Task { await model.stopWithAuth() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(16)
                }
                if model.alarmOn { AlarmScreen() }
            }
            .contentShape(Rectangle())
            .onTapGesture { showPeek() }
            .onReceive(move) { _ in
                spot = CGPoint(x: CGFloat.random(in: 160...max(161, geo.size.width - 20)),
                               y: CGFloat.random(in: 60...max(61, geo.size.height - 60)))
            }
        }
        .ignoresSafeArea()
    }

    private func showPeek() {
        peek = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if !Task.isCancelled { peek = false }
        }
    }
}

/// 警报时全红：告诉拿手机的人正在录像，只有机主能停
struct AlarmScreen: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Text("⚠️").font(.system(size: 80))
            Text("这台手机正在报警").font(.largeTitle.bold())
            Text("你的脸和声音正在被录下。\n请把手机放回原处。")
                .font(.title3).multilineTextAlignment(.center)
            Button("机主：停止警报") {
                Task { await model.stopAlarmWithAuth() }
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .padding(.top, 24)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.red)
    }
}

// MARK: 记录

struct RecordsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.records) { r in
                        NavigationLink {
                            RecordDetail(record: r)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(RecordsView.timeText(r.time))
                                Text(RecordsView.summary(r))
                                    .font(.footnote)
                                    .foregroundStyle(r.kind == .intrusion ? Color.secondary : Color.red)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { model.delete(model.records[i]) }
                    }
                } footer: {
                    Text("共占用 \(ByteCountFormatter.string(fromByteCount: model.usedBytes, countStyle: .file))，保留 \(model.keepDays) 天。手机空间不足 2 GB 时会先删最早的。")
                }
            }
            .overlay { if model.records.isEmpty { Text("还没有记录").foregroundStyle(.secondary) } }
            .navigationTitle("记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("关闭") { dismiss() } }
        }
    }

    static func timeText(_ t: TimeInterval) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    static func summary(_ r: Record) -> String {
        return "\(r.kind.title) · \(r.photos.count) 张照片 · \(r.videos.count) 段录像"
    }
}

struct RecordDetail: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let record: Record

    private func url(_ name: String) -> URL { model.pipe.store.url(id: record.id, name: name) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(record.videos, id: \.self) { name in
                    if FileManager.default.fileExists(atPath: url(name).path) {
                        VideoPlayer(player: AVPlayer(url: url(name)))
                            .aspectRatio(9.0 / 16.0, contentMode: .fit)
                        HStack {
                            ShareLink("分享", item: url(name))
                            Button("存进相册") { PhotoSaver.save(video: url(name)) }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                ForEach(record.photos, id: \.self) { name in
                    if let image = UIImage(contentsOfFile: url(name).path) {
                        Text(RecordStore.isFront(name) ? "前置摄像头（拍拿手机的人）" : "后置摄像头")
                            .font(.footnote).foregroundStyle(.secondary)
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                }
            }
            .padding()
        }
        .navigationTitle(record.kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("删除", role: .destructive) {
                model.delete(record)
                dismiss()
            }
        }
    }
}

// MARK: 系统控件

/// 把系统音量控件放进界面里（看不见），Siren 用它把音量推到最大
struct VolumeHolder: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let box = UIView()
        box.addSubview(VolumeBooster.shared.view)
        return box
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
