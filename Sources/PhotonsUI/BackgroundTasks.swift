import PhotonsLocalization
import AppKit
import SwiftUI
import PhotonsCore
import PhotonsExport
import PhotonsPanorama
import PhotonsJobs
import PhotonsFileAccess
import PhotonsCatalog

@MainActor
final class BackgroundTask:ObservableObject,Identifiable {
    enum State {case waiting,running,finished,failed,cancelled}
    let id=UUID()
    let title:String
    @Published var message=L10n.tr("8fb3a3261b43")
    @Published var fraction:Double?=0
    @Published var state=State.waiting
    @Published var output:URL?
    let token=CancellationToken()
    var process:Process?
    var onCancel:(()->Void)?
    init(_ title:String) {self.title=title}
    var active:Bool {state == .waiting || state == .running}
    func cancel() {token.cancel();message=L10n.tr("e8e08b0f61dd");onCancel?();if process?.isRunning == true {process?.terminate()}}
}

/// Owns jobs after all tool windows close. One large panorama at a time bounds memory/GPU
/// pressure, while each job's decoder/encoder is isolated in its own sandboxed process.
@MainActor
final class BackgroundTasks:ObservableObject {
    static let shared=BackgroundTasks()
    @Published var tasks:[BackgroundTask]=[]
    private var previewJobs:[UUID:PreviewPreparation]=[:]
    private let workerOverride:URL?
    init(worker:URL? = nil) {workerOverride=worker}
    private let work=DispatchQueue(label:"photons.panorama.jobs",qos:.utility)
    static let changed=Notification.Name("photons.backgroundTasksChanged")
    func changed() {objectWillChange.send();NotificationCenter.default.post(name:Self.changed,object:self)}
    var activeCount:Int {tasks.filter(\.active).count}
    func preparePreviews(assets:[Asset], provider:ThumbnailProvider, source:(Asset)->URL?) {
        let entries=assets.compactMap { asset -> (Asset,URL)? in source(asset).map {(asset,$0)} }
        guard !entries.isEmpty else {return}
        let task=BackgroundTask(L10n.tr("previews.title"))
        let job=PreviewPreparation(task:task,provider:provider,entries:entries) { [weak self] in
            self?.previewJobs.removeValue(forKey:task.id)
            self?.changed()
        }
        previewJobs[task.id]=job;tasks.append(task)
        task.onCancel = { [weak job] in job?.cancel() }
        job.start();changed()
    }
    func submit(plan:PanoramaPlan,manifest:PanoramaManifest,preset:ExportPreset,dng:Bool,directory:URL,
                completion:@escaping(URL,@escaping(String?)->Void)->Void) throws {
        let worker=Bundle.main.resourceURL?.appendingPathComponent("bin/photons-panorama-worker")
        let fallback=URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("photons-panorama-worker")
        let executable=workerOverride ?? ((worker.map {FileManager.default.isExecutableFile(atPath:$0.path)} == true) ? worker!:fallback)
        guard FileManager.default.isExecutableFile(atPath:executable.path) else {throw PanoramaFailure(L10n.tr("6b820899c037"))}
        let task=BackgroundTask(PanoramaManifest.defaultName(plan.sources.map(\.url)))
        tasks.append(task);changed()
        // Leases belong to the submitted task, not to its former window.
        let leases=(plan.sources.map(\.url)+plan.sources.map {$0.url.deletingLastPathComponent()}+[directory]).map {FileAccessStore.shared.access(to:$0)}
        let token=task.token
        work.async { [self] in
            defer {withExtendedLifetime(leases) {}}
            let folder=FileManager.default.temporaryDirectory.appendingPathComponent("photons-job-\(task.id.uuidString)",isDirectory:true)
            let sourceDirectory=plan.sources.map(\.url).sorted {$0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending}.first?.deletingLastPathComponent()
            let stagingRoot=preset.destination == .sourceFolder ? (sourceDirectory ?? directory):directory
            let staging=stagingRoot.appendingPathComponent(".photons-job-\(task.id.uuidString)",isDirectory:true)
            defer {try? FileManager.default.removeItem(at:folder);try? FileManager.default.removeItem(at:staging)}
            do {
                guard !token.isCancelled else {throw CancellationError()}
                DispatchQueue.main.async {task.state = .running;task.message=L10n.tr("c3bae02b0ab3");self.changed()}
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                let bookmarks=try leases.map {try $0.url.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil)}
                let job=PanoramaJob(snapshot:try PanoramaSnapshot(plan:plan),manifest:manifest,preset:preset,linearDNG:dng,outputDirectory:directory,bookmarks:bookmarks,stagingDirectory:staging)
                let request=folder.appendingPathComponent("request.json")
                try JSONEncoder().encode(job).write(to:request,options:.atomic)
                let process=Process(),pipe=Pipe()
                process.environment=ProcessInfo.processInfo.environment.merging(["PHOTONS_LANGUAGE":L10n.language]) {_,new in new}
                process.executableURL=executable;process.arguments=[request.path];process.standardOutput=pipe
                let errorURL=folder.appendingPathComponent("stderr.log")
                FileManager.default.createFile(atPath:errorURL.path,contents:nil)
                let errors=try FileHandle(forWritingTo:errorURL);defer {try? errors.close()}
                process.standardError=errors
                guard !token.isCancelled else {throw CancellationError()}
                try process.run()
                DispatchQueue.main.async {task.process=process;if token.isCancelled {process.terminate()}}
                var pending=Data(),last:PanoramaWorkerEvent?
                while let bytes=try pipe.fileHandleForReading.read(upToCount:8192),!bytes.isEmpty {
                    pending.append(bytes)
                    while let end=pending.firstIndex(of:10) {
                        let line=pending.prefix(upTo:end);pending.removeSubrange(...end)
                        guard let event=try? JSONDecoder().decode(PanoramaWorkerEvent.self,from:line) else {continue}
                        last=event
                        DispatchQueue.main.async {task.message=event.message;task.fraction=event.fraction;self.changed()}
                    }
                }
                process.waitUntilExit()
                guard !token.isCancelled || last?.result != nil else {throw CancellationError()}
                guard process.terminationStatus==0,last?.finished==true else {
                    throw PanoramaFailure(last?.error ?? L10n.tr("da27780eaea7"))
                }
                DispatchQueue.main.async {
                    task.process=nil;task.output=last?.result
                    if let url=last?.result {
                        task.message=L10n.tr("9d399493510f");task.fraction=nil;self.changed()
                        completion(url) {error in
                            task.message=error.map {L10n.tr("88f90bbd656e" , String(describing: ($0)))} ?? L10n.tr("36202891817c")
                            task.state=error == nil ? .finished:.failed;task.fraction=1;self.changed()
                            if !NSApp.isActive {_ = NSApp.requestUserAttention(.informationalRequest)}
                        }
                    } else {task.state = .finished;task.fraction=1;self.changed()}
                }
            } catch {
                try? FileManager.default.removeItem(at:staging)
                DispatchQueue.main.async {
                    task.process=nil;task.state=token.isCancelled ? .cancelled:.failed
                    task.message=token.isCancelled ? L10n.tr("a37778f17c5f"):error.localizedDescription;task.fraction=nil;self.changed()
                }
            }
        }
    }
}

private struct BackgroundTaskRow:View {
    @ObservedObject var task:BackgroundTask
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            HStack {Text(task.title).font(.headline);Spacer()
                if task.active {Button(L10n.tr("2cd0f3be8738")) {task.cancel()}}
                else if let url=task.output {Button(L10n.tr("fe76e31d24dd")) {NSWorkspace.shared.activateFileViewerSelecting([url])}}
            }
            Text(task.message).font(.caption).foregroundStyle(task.state == .failed ? .orange:.secondary)
            if task.active {
                if let fraction=task.fraction {ProgressView(value:fraction)} else {ProgressView().controlSize(.small)}
            }
        }.padding(12)
    }
}
private struct BackgroundTaskList:View {
    @ObservedObject var queue=BackgroundTasks.shared
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {Text(L10n.tr("4c46c904395c")).font(.headline);Spacer();Button(L10n.tr("349c4b7eb1f3")) {queue.tasks.removeAll {!$0.active};queue.changed()}}.padding(12)
            Divider()
            if queue.tasks.isEmpty {Text(L10n.tr("4277db85512d")).foregroundStyle(.secondary).padding(24)}
            ScrollView {LazyVStack(spacing:0) {ForEach(queue.tasks.reversed()) {BackgroundTaskRow(task:$0);Divider()}}}
        }.frame(width:390,height:320)
    }
}
@MainActor
final class BackgroundTaskButton:NSButton {
    private var observer:NSObjectProtocol?
    private var popover:NSPopover?
    private let progress=NSProgressIndicator()
    init() {
        super.init(frame:.zero);title=L10n.tr("5253040db864");bezelStyle = .texturedRounded;controlSize = .small
        image=NSImage(systemSymbolName:"list.bullet.rectangle",accessibilityDescription:nil);imagePosition = .imageLeading
        target=self;action=#selector(showTasks);setAccessibilityIdentifier("toolbar.tasks")
        progress.style = .bar;progress.isIndeterminate=false;progress.minValue=0;progress.maxValue=1;addSubview(progress)
        observer=NotificationCenter.default.addObserver(forName:BackgroundTasks.changed,object:nil,queue:.main) {[weak self] _ in self?.refresh()}
        refresh()
    }
    required init?(coder:NSCoder) {fatalError("no nib")}
    deinit {if let observer {NotificationCenter.default.removeObserver(observer)}}
    override func layout() {super.layout();progress.frame=CGRect(x:5,y:0,width:max(0,bounds.width-10),height:3)}
    private func refresh() {
        let queue=BackgroundTasks.shared
        title=queue.activeCount>0 ? L10n.tr("5cf043ec96db" , String(describing: (queue.activeCount))):L10n.tr("5253040db864")
        let current=queue.tasks.first {$0.state == .running}
        progress.isHidden=queue.activeCount==0
        progress.isIndeterminate=current?.fraction == nil
        if progress.isIndeterminate {progress.startAnimation(nil)} else {progress.stopAnimation(nil);progress.doubleValue=current?.fraction ?? 0}
        toolTip=current?.message ?? queue.tasks.last?.message ?? L10n.tr("4c46c904395c")
    }
    @objc private func showTasks() {
        let view=NSPopover();view.behavior = .transient;view.contentViewController=NSHostingController(rootView:BackgroundTaskList())
        popover=view;view.show(relativeTo:bounds,of:self,preferredEdge:.maxY)
    }
}
