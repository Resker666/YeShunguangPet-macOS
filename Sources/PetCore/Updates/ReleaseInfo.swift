import Foundation

public struct ReleaseVersion:Comparable,Equatable,Sendable,CustomStringConvertible {
    public let major,minor,patch:UInt32
    public init?(tag:String) {
        let raw=tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let parts=raw.split(separator:".",omittingEmptySubsequences:false)
        guard parts.count==3,parts.allSatisfy({!$0.isEmpty && $0.utf8.allSatisfy{(48...57).contains($0)}}),
              let a=UInt32(parts[0]),let b=UInt32(parts[1]),let c=UInt32(parts[2]) else{return nil}
        major=a;minor=b;patch=c
    }
    public var description:String {"\(major).\(minor).\(patch)"}
    public static func <(lhs:Self,rhs:Self)->Bool {(lhs.major,lhs.minor,lhs.patch)<(rhs.major,rhs.minor,rhs.patch)}
}
public enum ReleaseArchitecture:String,Sendable {case arm64,x86_64}
public enum ReleaseComparison:Equatable,Sendable {case newer,current,ahead}
public struct ReleaseInfo:Equatable,Sendable {
    public let version:ReleaseVersion
    public let tag:String
    public let pageURL:URL
    public let notes:String
    public let downloadURL:URL?
    private struct Payload:Decodable {
        struct Asset:Decodable {let name:String;let browser_download_url:String}
        let tag_name:String,draft:Bool,prerelease:Bool,html_url:String
        let body:String?
        let assets:[Asset]
    }
    public static func parse(_ data:Data,architecture:ReleaseArchitecture)throws->Self {
        guard data.count<=1_048_576 else{throw SkinError("更新响应超过 1 MiB")}
        let p=try JSONDecoder().decode(Payload.self,from:data)
        guard !p.draft,!p.prerelease,let version=ReleaseVersion(tag:p.tag_name) else{throw SkinError("公开版本格式无效")}
        let base="/Resker666/YeShunguangPet-macOS/releases"
        let page=try trustedURL(p.html_url,path:base+"/tag/"+p.tag_name)
        let number=p.tag_name.hasPrefix("v") ? String(p.tag_name.dropFirst()) : p.tag_name
        let filename="YeShunguangPet-\(number)-macOS-\(architecture.rawValue).dmg"
        let matches=p.assets.filter{$0.name==filename}
        guard matches.count<=1 else{throw SkinError("公开版本含重复的安装包")}
        let download=try matches.first.map{try trustedURL($0.browser_download_url,path:base+"/download/"+p.tag_name+"/"+filename)}
        return Self(version:version,tag:p.tag_name,pageURL:page,notes:String((p.body ?? "").prefix(8000)),downloadURL:download)
    }
    private static func trustedURL(_ string:String,path:String)throws->URL {
        guard let c=URLComponents(string:string),c.scheme=="https",c.host=="github.com",c.user==nil,c.password==nil,c.port==nil,c.query==nil,c.fragment==nil,
              c.percentEncodedPath==path,let url=c.url else{throw SkinError("更新链接不属于本项目的官方发布路径")}
        return url
    }
    public func comparison(to current:ReleaseVersion)->ReleaseComparison {version>current ? .newer : version==current ? .current : .ahead}
}
