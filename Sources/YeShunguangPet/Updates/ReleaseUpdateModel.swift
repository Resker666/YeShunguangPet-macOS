import Foundation
import Combine
import PetCore

enum ReleaseUpdateState:Equatable {
    case idle,checking,success(ReleaseInfo,ReleaseComparison),failure(String)
}
@MainActor final class ReleaseUpdateModel:ObservableObject {
    @Published private(set) var state=ReleaseUpdateState.idle
    let currentVersion:ReleaseVersion
    let architecture:ReleaseArchitecture
    private let client:any ReleaseFetching
    private var task:Task<Void,Never>?
    private var generation:UInt64=0
    init(currentVersion:ReleaseVersion,architecture:ReleaseArchitecture,client:any ReleaseFetching) {
        self.currentVersion=currentVersion;self.architecture=architecture;self.client=client
    }
    func check() {
        guard task==nil else{return}
        generation &+= 1
        let current=generation,client=client,architecture=architecture
        state = .checking
        task=Task { [weak self] in
            do {
                let info=try await client.fetchLatest(architecture:architecture)
                guard let self,self.generation==current,!Task.isCancelled else{return}
                self.state = .success(info,info.comparison(to:self.currentVersion));self.task=nil
            } catch {
                guard let self,self.generation==current,!Task.isCancelled else{return}
                self.state = .failure("查询未完成：\(error.localizedDescription) 可再次检查。")
                self.task=nil
            }
        }
    }
    func cancel() {
        generation &+= 1;task?.cancel();task=nil
        if state == .checking {state = .idle}
    }
}
