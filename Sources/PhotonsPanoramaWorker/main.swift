import PhotonsLocalization
import Foundation
import PhotonsJobs

func emit(_ event:PanoramaWorkerEvent) {
    if var data=try? JSONEncoder().encode(event) {data.append(10);FileHandle.standardOutput.write(data)}
}
do {
    guard CommandLine.arguments.count==2 else {throw CocoaError(.fileReadInvalidFileName)}
    let job=try JSONDecoder().decode(PanoramaJob.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
    let result=try autoreleasepool {try job.run {emit(.init(message:$0,fraction:$1))}}
    emit(.init(message:result == nil ? L10n.tr("538a8818a398"):L10n.tr("3e6886d17a1c"),fraction:1,result:result,finished:true))
} catch {
    emit(.init(message:L10n.tr("6e4445df6957"),finished:true,error:error.localizedDescription));exit(1)
}
