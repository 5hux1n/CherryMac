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
        let originalPreferenceValue=CFPreferencesCopyAppValue("NSServicesStatus" as CFString,domain)
        guard originalPreferenceValue==nil || originalPreferenceValue is [String:Any] else{throw HardwareError(message:"系统服务偏好格式无效，未安装快捷操作。")}
        var preferences=originalPreferenceValue as? [String:Any] ?? [:]
        let key="\(bundleID) - \(name) - runWorkflowAsService",legacyKey="(null) - \(name) - runWorkflowAsService"
        guard !preferences.contains(where:{entry in
            entry.key != key && entry.key != legacyKey && ((entry.value as? [String:Any])?["key_equivalent"] as? String)?.lowercased()==shortcut.equivalent
        })else{throw HardwareError(message:"该组合键已被其他系统快捷操作使用，请先在系统键盘设置中调整。未更改服务或键位。")}
        let directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Services/\(name).workflow/Contents")
        let existingInfo=directory.appendingPathComponent("Info.plist")
        if FileManager.default.fileExists(atPath:directory.deletingLastPathComponent().path){
            guard let existing=(try? PropertyListSerialization.propertyList(from:Data(contentsOf:existingInfo),format:nil)) as? [String:Any],existing["CFBundleIdentifier"] as? String==bundleID else{throw HardwareError(message:"同名快捷操作不是 CherryMac 创建的，未覆盖。")}
        }
        let manager=FileManager.default,workflow=directory.deletingLastPathComponent()
        let workflowExisted=manager.fileExists(atPath:workflow.path)
        let serialized=try [("Info.plist",files.info),("document.wflow",files.document)].map{file,object in
            (directory.appendingPathComponent(file),try PropertyListSerialization.data(fromPropertyList:object,format:.xml,options:0))
        }
        // Capture all touched files before the first mutation. Unrelated files
        // and preference entries are never removed during rollback.
        let originals=try serialized.map{url,_ -> Data? in
            if !manager.fileExists(atPath:url.path){return nil}
            let values=try url.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey])
            guard values.isSymbolicLink != true,values.isRegularFile==true else{throw HardwareError(message:"快捷操作文件不是普通文件，未修改。")}
            return try Data(contentsOf:url)
        }
        let originalEntry=preferences[key],originalLegacy=preferences[legacyKey]
        func samePreference(_ left:Any?,_ right:Any?)->Bool{
            switch (left,right){case (nil,nil):return true
            case (let left?,let right?):return NSDictionary(dictionary:["value":left]).isEqual(NSDictionary(dictionary:["value":right]))
            default:return false}
        }
        func currentPreferences()throws->[String:Any]{
            guard let value=CFPreferencesCopyAppValue("NSServicesStatus" as CFString,domain)else{return [:]}
            guard let result=value as? [String:Any]else{throw HardwareError(message:"系统服务偏好格式已改变，停止修改。")};return result
        }
        func registerServices()throws{
            let process=Process();process.executableURL=URL(fileURLWithPath:"/System/Library/CoreServices/pbs");process.arguments=["-update"]
            try process.run();process.waitUntilExit()
            guard process.terminationStatus==0 else{throw HardwareError(message:"系统快捷操作注册失败。")}
            NSUpdateDynamicServices()
        }
        var installedEntry:[String:Any]?,preferencesTouched=false,registrationAttempted=false
        do{
            try manager.createDirectory(at:directory,withIntermediateDirectories:true)
            for (url,data) in serialized{try data.write(to:url,options:.atomic)}
            // Re-read to preserve preference edits made while files were saved.
            preferences=try currentPreferences()
            guard samePreference(preferences[key],originalEntry),samePreference(preferences[legacyKey],originalLegacy)else{throw HardwareError(message:"此快捷操作的系统设置已被其他程序修改，停止安装。")}
            guard !preferences.contains(where:{entry in entry.key != key && entry.key != legacyKey && ((entry.value as? [String:Any])?["key_equivalent"] as? String)?.lowercased()==shortcut.equivalent})else{throw HardwareError(message:"组合键已被其他系统快捷操作占用，停止安装。")}
            preferences.removeValue(forKey:legacyKey)
            var entry=preferences[key] as? [String:Any] ?? [:]
            entry["key_equivalent"]=shortcut.equivalent;entry["enabled_services_menu"]=true;entry["enabled_context_menu"]=true
            entry["presentation_modes"]=["ServicesMenu":true,"ContextMenu":true];preferences[key]=entry;installedEntry=entry
            preferencesTouched=true
            CFPreferencesSetAppValue("NSServicesStatus" as CFString,preferences as CFDictionary,domain)
            guard CFPreferencesAppSynchronize(domain)else{throw HardwareError(message:"系统快捷键偏好保存失败。")}
            registrationAttempted=true;try registerServices()
        }catch{
            let failure=error.localizedDescription;var rollbackFailures:[String]=[]
            for (index,item) in serialized.enumerated(){
                let (url,newData)=item,oldData=originals[index]
                do{
                    let current=manager.fileExists(atPath:url.path) ? try Data(contentsOf:url):nil
                    if current==oldData{continue}
                    guard current==newData else{throw HardwareError(message:"文件已被其他程序改变，未覆盖：\(url.lastPathComponent)")}
                    if let oldData{try oldData.write(to:url,options:.atomic)}else{try manager.removeItem(at:url)}
                }catch{rollbackFailures.append(error.localizedDescription)}
            }
            if !workflowExisted{
                // Remove only empty directories created by this installation.
                for url in [directory,workflow]{
                    do{if manager.fileExists(atPath:url.path),try manager.contentsOfDirectory(atPath:url.path).isEmpty{try manager.removeItem(at:url)}}
                    catch{rollbackFailures.append(error.localizedDescription)}
                }
            }
            if preferencesTouched{
                do{
                    var current=try currentPreferences()
                    for (entryKey,original,written) in [(key,originalEntry,installedEntry as Any?),(legacyKey,originalLegacy,nil as Any?)]{
                        if samePreference(current[entryKey],original){continue}
                        guard samePreference(current[entryKey],written)else{rollbackFailures.append("系统快捷操作设置已被其他程序改变，未覆盖："+entryKey);continue}
                        if let original{current[entryKey]=original}else{current.removeValue(forKey:entryKey)}
                    }
                    if current.isEmpty,originalPreferenceValue==nil{CFPreferencesSetAppValue("NSServicesStatus" as CFString,nil,domain)}
                    else{CFPreferencesSetAppValue("NSServicesStatus" as CFString,current as CFDictionary,domain)}
                    guard CFPreferencesAppSynchronize(domain)else{throw HardwareError(message:"原快捷键偏好恢复失败。")}
                }catch{rollbackFailures.append(error.localizedDescription)}
            }
            if registrationAttempted{
                do{try registerServices()}catch{rollbackFailures.append("恢复服务注册："+error.localizedDescription)}
            }
            throw HardwareError(message:"安装失败：\(failure)\n"+(rollbackFailures.isEmpty ? "已恢复本次修改的文件和快捷键设置；键位草稿未改变。":"部分恢复未完成："+rollbackFailures.joined(separator:"；")+"。键位草稿未改变。"))
        }
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
