import AppKit

// Automator and the system Services menu own execution; CherryMac does not
// remain running to watch the Calculator key.
enum CalculatorService {
    static let name="CherryMac 打开计算器"
    static let bundleID="local.cherrymac.calculator-service"
    static func definition(system:[String:Any]) throws -> (info:[String:Any],document:[String:Any]) {
        let actionPath="/System/Library/Automator/Run Shell Script.action"
        guard let accepts=system["AMAccepts"],let provides=system["AMProvides"],let version=system["CFBundleVersion"] as? String,let actionClass=system["NSPrincipalClass"] as? String else{throw HardwareError(message:"系统缺少 Automator Shell Script 动作。")}
        let parameters:[String:Any]=["COMMAND_STRING":"/usr/bin/open -b com.apple.calculator","shell":"/bin/zsh","inputMethod":0,"source":"","CheckedForUserDefaultShell":false]
        let action:[String:Any]=["ActionBundlePath":actionPath,"ActionName":"Run Shell Script","ActionParameters":parameters,"AMAccepts":accepts,"AMProvides":provides,"AMActionVersion":version,"AMApplication":["Automator"],"AMParameterProperties":Dictionary(uniqueKeysWithValues:parameters.keys.map{($0, [String:Any]())}),"BundleIdentifier":"com.apple.RunShellScript","Class Name":actionClass,"CanShowWhenRun":true,"CanShowSelectedItemsWhenRun":false,"CFBundleVersion":version,"UUID":UUID().uuidString,"InputUUID":UUID().uuidString,"OutputUUID":UUID().uuidString]
        let info:[String:Any]=["CFBundleIdentifier":bundleID,"CFBundleName":name,"CFBundlePackageType":"BNDL","CFBundleVersion":"1","NSServices":[["NSMenuItem":["default":name],"NSMessage":"runWorkflowAsService","NSRequiredContext":[String:Any](),"NSSendTypes":[String]()]]]
        let document:[String:Any]=["AMDocumentVersion":"2","actions":[["action":action,"isViewVisible":true]],"connectors":[String:Any](),"workflowMetaData":["workflowTypeIdentifier":"com.apple.Automator.servicesMenu","serviceInputTypeIdentifier":"com.apple.Automator.nothing","serviceOutputTypeIdentifier":"com.apple.Automator.nothing","serviceProcessesInput":false]]
        return (info,document)
    }
    static func install() throws {
        let systemData=try Data(contentsOf:URL(fileURLWithPath:"/System/Library/Automator/Run Shell Script.action/Contents/Info.plist"))
        guard let system=try PropertyListSerialization.propertyList(from:systemData,format:nil) as? [String:Any] else{throw HardwareError(message:"系统缺少 Automator Shell Script 动作。")}
        let files=try definition(system:system)
        let directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Services/\(name).workflow/Contents")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        for (file,object) in [("Info.plist",files.info),("document.wflow",files.document)]{
            try PropertyListSerialization.data(fromPropertyList:object,format:.xml,options:0).write(to:directory.appendingPathComponent(file),options:.atomic)
        }
        let domain="pbs" as CFString
        var preferences=CFPreferencesCopyAppValue("NSServicesStatus" as CFString,domain) as? [String:Any] ?? [:]
        preferences.removeValue(forKey:"(null) - \(name) - runWorkflowAsService")
        let key="\(bundleID) - \(name) - runWorkflowAsService"
        // Keep every unrelated service's preferences, including its shortcut.
        var entry=preferences[key] as? [String:Any] ?? [:]
        entry["key_equivalent"]="^~@c";entry["enabled_services_menu"]=true;entry["enabled_context_menu"]=true
        entry["presentation_modes"]=["ServicesMenu":true,"ContextMenu":true];preferences[key]=entry
        CFPreferencesSetAppValue("NSServicesStatus" as CFString,preferences as CFDictionary,domain)
        guard CFPreferencesAppSynchronize(domain)else{throw HardwareError(message:"系统快捷键偏好保存失败。")}
        let process=Process();process.executableURL=URL(fileURLWithPath:"/System/Library/CoreServices/pbs");process.arguments=["-update"]
        try process.run();process.waitUntilExit()
        guard process.terminationStatus==0 else{throw HardwareError(message:"系统快捷操作注册失败。")}
        NSUpdateDynamicServices()
    }
}
