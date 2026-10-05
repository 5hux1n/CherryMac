import AppKit

// Automator and the system Services menu own execution; CherryMac does not
// remain running to watch the Calculator key.
enum MacApplicationShortcut:CaseIterable {
    case calculator, finder, mail, music
    var title:String{switch self{case .calculator:return "计算器";case .finder:return "Finder";case .mail:return "邮件";case .music:return "音乐"}}
    var serviceName:String{"CherryMac 打开"+title}
    var serviceBundleID:String{switch self{case .calculator:return "local.cherrymac.calculator-service";case .finder:return "local.cherrymac.finder-service";case .mail:return "local.cherrymac.mail-service";case .music:return "local.cherrymac.music-service"}}
    var applicationBundleID:String{switch self{case .calculator:return "com.apple.calculator";case .finder:return "com.apple.finder";case .mail:return "com.apple.mail";case .music:return "com.apple.Music"}}
    var applicationPath:String{switch self{case .calculator:return "/System/Applications/Calculator.app";case .finder:return "/System/Library/CoreServices/Finder.app";case .mail:return "/System/Applications/Mail.app";case .music:return "/System/Applications/Music.app"}}
    var usage:UInt8{switch self{case .calculator:return 6;case .finder:return 9;case .mail:return 16;case .music:return 19}}
    var equivalent:String{switch self{case .calculator:return "^~@c";case .finder:return "^~@f";case .mail:return "^~@m";case .music:return "^~@p"}}
    var record:[UInt8]{[0x20,0x0d,usage]}
}

enum ApplicationShortcutService {
    static func configureApplicationMenu(){
        let main=NSMenu(),appItem=NSMenuItem(),appMenu=NSMenu(title:"CherryMac")
        appItem.submenu=appMenu;main.addItem(appItem)
        let services=NSMenu(title:"服务"),item=NSMenuItem(title:"服务",action:nil,keyEquivalent:"")
        item.submenu=services;appMenu.addItem(item);appMenu.addItem(.separator())
        let quit=NSMenuItem(title:"退出 CherryMac",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");quit.target=NSApp;appMenu.addItem(quit)
        let edit=NSMenu(title:"编辑"),editItem=NSMenuItem(title:"编辑",action:nil,keyEquivalent:"");editItem.submenu=edit;main.addItem(editItem)
        for (title,action,key) in [("撤销","undo:","z"),("剪切","cut:","x"),("拷贝","copy:","c"),("粘贴","paste:","v"),("全选","selectAll:","a")]{edit.addItem(NSMenuItem(title:title,action:Selector(action),keyEquivalent:key))}
        NSApp.servicesMenu=services;NSApp.mainMenu=main
        NSApp.registerServicesMenuSendTypes([.string,.fileURL],returnTypes:[])
        NSUpdateDynamicServices()
    }
    static func definition(system:[String:Any],shortcut:MacApplicationShortcut) throws -> (info:[String:Any],document:[String:Any]) {
        let name=shortcut.serviceName,bundleID=shortcut.serviceBundleID
        let actionPath="/System/Library/Automator/Run Shell Script.action"
        guard let accepts=system["AMAccepts"],let provides=system["AMProvides"],let version=system["CFBundleVersion"] as? String,let actionClass=system["NSPrincipalClass"] as? String else{throw HardwareError(message:"系统缺少 Automator Shell Script 动作。")}
        let parameters:[String:Any]=["COMMAND_STRING":"/usr/bin/open -b \(shortcut.applicationBundleID)","shell":"/bin/zsh","inputMethod":0,"source":"","CheckedForUserDefaultShell":false]
        let action:[String:Any]=["ActionBundlePath":actionPath,"ActionName":"Run Shell Script","ActionParameters":parameters,"AMAccepts":accepts,"AMProvides":provides,"AMActionVersion":version,"AMApplication":["Automator"],"AMParameterProperties":Dictionary(uniqueKeysWithValues:parameters.keys.map{($0, [String:Any]())}),"BundleIdentifier":"com.apple.RunShellScript","Class Name":actionClass,"CanShowWhenRun":true,"CanShowSelectedItemsWhenRun":false,"CFBundleVersion":version,"UUID":UUID().uuidString,"InputUUID":UUID().uuidString,"OutputUUID":UUID().uuidString]
        let info:[String:Any]=["CFBundleIdentifier":bundleID,"CFBundleName":name,"CFBundlePackageType":"BNDL","CFBundleVersion":"1","NSServices":[["NSMenuItem":["default":name],"NSMessage":"runWorkflowAsService","NSRequiredContext":[String:Any](),"NSSendTypes":[String]()]]]
        let document:[String:Any]=["AMDocumentVersion":"2","actions":[["action":action,"isViewVisible":true]],"connectors":[String:Any](),"workflowMetaData":["workflowTypeIdentifier":"com.apple.Automator.servicesMenu","serviceInputTypeIdentifier":"com.apple.Automator.nothing","serviceOutputTypeIdentifier":"com.apple.Automator.nothing","serviceProcessesInput":false]]
        return (info,document)
    }
    static func install(_ shortcut:MacApplicationShortcut) throws {
        let name=shortcut.serviceName,bundleID=shortcut.serviceBundleID
        guard FileManager.default.fileExists(atPath:shortcut.applicationPath)else{throw HardwareError(message:"系统中未找到\(shortcut.title)，尚未安装快捷操作。")}
        let systemData=try Data(contentsOf:URL(fileURLWithPath:"/System/Library/Automator/Run Shell Script.action/Contents/Info.plist"))
        guard let system=try PropertyListSerialization.propertyList(from:systemData,format:nil) as? [String:Any] else{throw HardwareError(message:"系统缺少 Automator Shell Script 动作。")}
        let files=try definition(system:system,shortcut:shortcut)
        let domain="pbs" as CFString
        var preferences=CFPreferencesCopyAppValue("NSServicesStatus" as CFString,domain) as? [String:Any] ?? [:]
        let key="\(bundleID) - \(name) - runWorkflowAsService",legacyKey="(null) - \(name) - runWorkflowAsService"
        guard !preferences.contains(where:{entry in
            entry.key != key && entry.key != legacyKey && ((entry.value as? [String:Any])?["key_equivalent"] as? String)?.lowercased()==shortcut.equivalent
        })else{throw HardwareError(message:"该组合键已被其他系统快捷操作使用，请先在系统键盘设置中调整。未更改服务或键位。")}
        let directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Services/\(name).workflow/Contents")
        let existingInfo=directory.appendingPathComponent("Info.plist")
        if FileManager.default.fileExists(atPath:directory.deletingLastPathComponent().path){
            guard let existing=(try? PropertyListSerialization.propertyList(from:Data(contentsOf:existingInfo),format:nil)) as? [String:Any],existing["CFBundleIdentifier"] as? String==bundleID else{throw HardwareError(message:"同名快捷操作不是 CherryMac 创建的，未覆盖。")}
        }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        for (file,object) in [("Info.plist",files.info),("document.wflow",files.document)]{
            try PropertyListSerialization.data(fromPropertyList:object,format:.xml,options:0).write(to:directory.appendingPathComponent(file),options:.atomic)
        }
        preferences.removeValue(forKey:legacyKey)
        // Keep every unrelated service's preferences, including its shortcut.
        var entry=preferences[key] as? [String:Any] ?? [:]
        entry["key_equivalent"]=shortcut.equivalent;entry["enabled_services_menu"]=true;entry["enabled_context_menu"]=true
        entry["presentation_modes"]=["ServicesMenu":true,"ContextMenu":true];preferences[key]=entry
        CFPreferencesSetAppValue("NSServicesStatus" as CFString,preferences as CFDictionary,domain)
        guard CFPreferencesAppSynchronize(domain)else{throw HardwareError(message:"系统快捷键偏好保存失败。")}
        let process=Process();process.executableURL=URL(fileURLWithPath:"/System/Library/CoreServices/pbs");process.arguments=["-update"]
        try process.run();process.waitUntilExit()
        guard process.terminationStatus==0 else{throw HardwareError(message:"系统快捷操作注册失败。")}
        NSUpdateDynamicServices()
    }
}

// Preserve the existing calculator API and workflow identity.
enum CalculatorService {
    static let name=MacApplicationShortcut.calculator.serviceName
    static let bundleID=MacApplicationShortcut.calculator.serviceBundleID
    static func configureApplicationMenu(){ApplicationShortcutService.configureApplicationMenu()}
    static func definition(system:[String:Any])throws->(info:[String:Any],document:[String:Any]){try ApplicationShortcutService.definition(system:system,shortcut:.calculator)}
    static func install()throws{try ApplicationShortcutService.install(.calculator)}
}
