import AppKit

final class HardwareCanvas: NSView {
    override var isFlipped:Bool {true}
    override func draw(_ dirtyRect:NSRect){NSColor.windowBackgroundColor.setFill();bounds.fill()}
}

final class HardwareNavigationButton:NSButton {
    override func draw(_ dirtyRect:NSRect){
        let active=state == .on
        if active{NSColor.controlAccentColor.withAlphaComponent(0.14).setFill();NSBezierPath(roundedRect:bounds,xRadius:8,yRadius:8).fill()}
        let text=NSAttributedString(string:title,attributes:[.font:NSFont.systemFont(ofSize:13,weight:active ? .semibold:.regular),.foregroundColor:active ? NSColor.controlAccentColor:NSColor.labelColor])
        let size=text.size();text.draw(at:NSPoint(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2))
        if window?.firstResponder === self{NSColor.keyboardFocusIndicatorColor.setStroke();let ring=NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:8,yRadius:8);ring.lineWidth=2;ring.stroke()}
    }
}

final class HardwareWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    let root = HardwareCanvas(frame:NSRect(x:0,y:0,width:1152,height:860))
    let board = FlippedView(frame:NSRect(x:87,y:120,width:866,height:260))
    let connection = NSTextField(labelWithString:"尚未读取键盘")
    let message = NSTextField(wrappingLabelWithString:"用 USB 数据线连接键盘并切到有线模式，然后读取配置。")
    let selectedLabel = NSTextField(labelWithString:"计算器")
    let pageTitle = NSTextField(labelWithString:"按键功能")
    let pageDescription = NSTextField(labelWithString:"点选一个按键，设置你习惯的功能。")
    var lightTabView:NSTabView?
    var lightTabButtons:[NSButton]=[]
    let globalLightColor=NSColorWell()
    var writeButtons:[NSButton]=[]
    let recordLabel = NSTextField(labelWithString:"点击键盘上的按键查看当前功能")
    let actionPicker = NSPopUpButton()
    let keyPicker = NSPopUpButton()
    let modePicker = NSPopUpButton()
    let brightness = NSSlider(value:4,minValue:0,maxValue:4,target:nil,action:nil)
    let speed = NSSlider(value:2,minValue:0,maxValue:4,target:nil,action:nil)
    let color = NSColorWell()
    let endColor = NSColorWell()
    let lightHex = NSTextField(string:"#FFFFFF")
    let lightRGB = [NSTextField(string:"255"),NSTextField(string:"255"),NSTextField(string:"255")]
    let lightStrength = NSSlider(value:100,minValue:0,maxValue:100,target:nil,action:nil)
    let lightStrengthLabel = NSTextField(labelWithString:"100%")
    let lightCount = NSTextField(labelWithString:"已选 1 键")
    let lightMultiple = NSButton(checkboxWithTitle:"多选",target:nil,action:nil)
    let lightRegion = NSPopUpButton()
    let lightPattern = NSPopUpButton()
    let lightDirection = NSPopUpButton()
    let lightRainbow = NSPopUpButton()
    var lightSelection:Set<String> = ["calculator"]
    var colorEditSource=0
    let modifiers = [NSButton(checkboxWithTitle:"⌘ Command",target:nil,action:nil),NSButton(checkboxWithTitle:"⌃ Control",target:nil,action:nil),NSButton(checkboxWithTitle:"⌥ Option",target:nil,action:nil),NSButton(checkboxWithTitle:"⇧ Shift",target:nil,action:nil)]
    let macroName = NSTextField(string:"新宏")
    let macroText = NSTextView()
    let macroPicker = NSPopUpButton()
    let macroKey = NSPopUpButton()
    let macroDelay = NSTextField(string:"50")
    let queue = DispatchQueue(label:"local.cherrymac.hardware")
    var keyButtons:[KeyButton] = []
    var tabButtons:[NSButton]=[]
    var tabView:NSTabView?
    var selected = "calculator"
    var profile:HardwareProfile?
    var baseline:HardwareSnapshot?
    var busy=false
    var lastKeyBackup:URL?{UserDefaults.standard.string(forKey:"hardware.lastKeyBackup").map{URL(fileURLWithPath:$0)}}
    var controls:[NSControl]=[]
    var modes:[(String,UInt8)] = [("保留当前模式",23)] + CherryLighting.modes
    let hidKeys:[(String,UInt8)] = {
        var keys:[(String,UInt8)]=[]
        for usage in 4...29 { keys.append((String(UnicodeScalar(usage-4+65)!),UInt8(usage))) }
        keys += [("1",30),("2",31),("3",32),("4",33),("5",34),("6",35),("7",36),("8",37),("9",38),("0",39),("Enter",40),("Esc",41),("Space",44)]
        for n in 1...12 {keys.append(("F\(n)",UInt8(57+n)))}
        for n in 13...24 {keys.append(("F\(n)",UInt8(91+n)))}
        keys += [("左 Control",224),("左 Shift",225),("左 Option",226),("左 Command",227),("右 Control",228),("右 Shift",229),("右 Option",230),("右 Command",231)]
        for spec in keyboardLayout(){
            guard let signal=spec.usage?.split(separator:":"),signal.count==2,signal[0]=="7",let usage=UInt8(signal[1]),!keys.contains(where:{$0.1==usage})else{continue}
            keys.append((spec.label.replacingOccurrences(of:"\n",with:" / "),usage))
        }
        keys.append(("仅修饰键",0))
        return keys
    }()
    var shortcutKeys:[(String,UInt8)] {hidKeys.filter{$0.1<224}}
    init() {
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1152,height:860),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init(window:window)
        window.title="CherryMac · 键盘配置";window.minSize=NSSize(width:1152,height:650);window.center();window.delegate=self
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=false;scroll.documentView=root;window.contentView=scroll
        build()
    }
    required init?(coder:NSCoder){fatalError()}
    func place(_ view:NSView,_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat,in parent:NSView?=nil){view.frame=NSRect(x:x,y:y,width:w,height:h);(parent ?? root).addSubview(view)}
    func label(_ title:String,_ size:CGFloat=13,_ weight:NSFont.Weight = .regular)->NSTextField{let l=NSTextField(wrappingLabelWithString:title);l.font = .systemFont(ofSize:size,weight:weight);return l}
    func button(_ title:String,_ selector:Selector)->NSButton{let b=NSButton(title:title,target:self,action:selector);controls.append(b);return b}
    func build(){
        let sidebar=NSBox();sidebar.boxType = .custom;sidebar.borderWidth=0;sidebar.fillColor = .controlBackgroundColor;sidebar.cornerRadius=0
        place(sidebar,0,0,166,860)
        place(label("CherryMac",22,.semibold),22,24,142,32)
        place(label("键盘配置",12),23,60,132,22)
        pageTitle.font = .systemFont(ofSize:27,weight:.semibold)
        place(pageTitle,192,24,654,39);pageDescription.textColor = .secondaryLabelColor;place(pageDescription,192,68,665,23)
        place(button("读取键盘",#selector(readKeyboard)),997,30,126,32)
        connection.textColor = .secondaryLabelColor;place(connection,192,106,920,23)
        place(label("按键可独立写入；灯效和宏可编辑、保存，实体写入暂缓。",12),192,140,925,24)
        board.frame.origin=NSPoint(x:225,y:178);root.addSubview(board)
        for spec in keyboardLayout(){let key=KeyButton(spec);key.hardwareConfigurable=true;if spec.id=="cherry"{key.title="CH"};key.target=self;key.action=#selector(selectKey(_:));board.addSubview(key);keyButtons.append(key)}
        let tabs=NSTabView();tabs.tabViewType = .noTabsNoBorder;tabView=tabs;place(tabs,192,462,936,294)
        let titles=["键位","灯效","宏","配置与备份","设备与诊断"]
        for title in titles{let item=NSTabViewItem(identifier:title);item.label=title;item.view=FlippedView();tabs.addTabViewItem(item)}
        for (index,title) in titles.enumerated(){
            let tab=HardwareNavigationButton(title:title,target:self,action:#selector(chooseTab(_:)));tab.tag=index;tab.isBordered=false;tab.setButtonType(.toggle)
            place(tab,14,124+CGFloat(index)*49,140,36);tabButtons.append(tab)
        }
        place(label("MX 3.0S POKÉMON\nWireless",11),23,759,130,46)
        let keys=tabs.tabViewItems[0].view!
        selectedLabel.font = .systemFont(ofSize:19,weight:.semibold)
        place(selectedLabel,8,8,240,29,in:keys);place(recordLabel,8,48,235,62,in:keys)
        place(label("设置功能"),282,12,86,23,in:keys)
        actionPicker.addItems(withTitles:["保留当前功能","快捷键组合","打开系统计算器","框选区域截图","刷新 · ⌘R","上一曲","播放 / 暂停","下一曲","禁用"])
        actionPicker.target=self;actionPicker.action=#selector(actionChanged);controls.append(actionPicker)
        place(actionPicker,378,8,235,28,in:keys)
        place(label("快捷键主键"),282,57,95,23,in:keys)
        keyPicker.addItems(withTitles:shortcutKeys.map{$0.0});controls.append(keyPicker);place(keyPicker,378,53,155,28,in:keys)
        for (i,m) in modifiers.enumerated(){controls.append(m);place(m,282+CGFloat(i%2)*196,99+CGFloat(i/2)*31,185,25,in:keys)}
        place(button("保存到编辑区",#selector(stageKey)),282,182,186,30,in:keys)
        place(button("安装计算器快捷操作",#selector(installCalculator)),8,161,230,30,in:keys)
        place(label("系统计算器使用 macOS 快捷操作。\n安装后可把计算器键设置为 ⌃⌥⌘C。",12),8,210,236,60,in:keys)
        buildLighting(tabs.tabViewItems[1].view!)
        let macros=tabs.tabViewItems[2].view!
        place(label("已保存的宏"),8,12,100,24,in:macros)
        macroPicker.addItem(withTitle:"新建宏");macroPicker.target=self;macroPicker.action=#selector(chooseMacro);controls.append(macroPicker);place(macroPicker,116,8,226,28,in:macros)
        place(button("删除宏",#selector(deleteMacro)),359,8,90,28,in:macros)
        place(label("名称"),8,57,90,24,in:macros);controls.append(macroName);place(macroName,116,53,333,28,in:macros)
        let macroScroll=NSScrollView(frame:NSRect(x:8,y:99,width:552,height:154));macroScroll.hasVerticalScroller=true;macroScroll.borderType = .bezelBorder
        macroText.frame=NSRect(origin:.zero,size:macroScroll.contentSize);macroText.minSize=NSSize(width:0,height:macroScroll.contentSize.height);macroText.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        macroText.isVerticallyResizable=true;macroText.isHorizontallyResizable=false;macroText.autoresizingMask = .width;macroText.textContainer?.widthTracksTextView=true;macroText.textContainerInset=NSSize(width:10,height:10)
        macroScroll.documentView=macroText;macroText.isRichText=false;macroText.font = .monospacedSystemFont(ofSize:13,weight:.regular);macroText.string="A 按下 0\nA 松开 50";macros.addSubview(macroScroll)
        place(label("添加按键"),593,12,110,24,in:macros)
        macroKey.addItems(withTitles:hidKeys.filter{$0.1 != 0}.map{$0.0});controls.append(macroKey);place(macroKey,707,8,168,28,in:macros)
        place(label("间隔（毫秒）"),593,57,110,24,in:macros);controls.append(macroDelay);place(macroDelay,707,53,168,28,in:macros)
        place(button("添加按下与松开",#selector(appendMacroKey)),593,99,282,30,in:macros)
        place(button("保存宏",#selector(stageMacro)),593,144,282,30,in:macros)
        place(button("分配到选中的键",#selector(assignMacro)),593,189,282,30,in:macros)
        place(label("执行一次。实体触发、循环与鼠标宏仍在验证。",11),593,233,282,44,in:macros)
        let files=tabs.tabViewItems[3].view!
        place(label("配置文件",20,.semibold),8,12,850,30,in:files)
        place(label("导入到编辑区，或把当前配置保存成文件。",13),8,52,850,26,in:files)
        place(button("导入配置…",#selector(importProfile)),8,94,180,32,in:files)
        place(button("导出配置…",#selector(exportProfile)),208,94,180,32,in:files)
        place(label("备份与撤销",17,.semibold),8,160,850,27,in:files)
        place(button("打开自动备份",#selector(openBackups)),8,205,180,32,in:files)
        place(button("撤销编辑区修改",#selector(discardDraft)),208,205,210,32,in:files)
        place(button("恢复最近按键备份",#selector(restoreLastKeys)),438,205,222,32,in:files)
        place(label("支持 CherryMac 配置与本型号 Windows JSON。Windows 导入前先读取键盘。导入和撤销均不修改实体键盘。",12),8,261,850,62,in:files)
        let device=tabs.tabViewItems[4].view!
        place(label("设备与诊断",20,.semibold),8,12,850,30,in:device)
        place(label("MX 3.0S Pokémon Wireless\n通过 USB 数据线连接，并切换到有线模式。",13),8,61,850,56,in:device)
        place(label("仅开放按键写入，自动备份、逐包检查释放并完整读回。灯效与宏写入暂缓。\nWin 锁、6 键／全键模式、回报率等设置会在协议确认后加入。",13),8,148,850,70,in:device)
        place(button("打开操作日志",#selector(openLogs)),261,253,180,32,in:device)
        place(button("Mac 端按键适配设置",#selector(openMacSettings)),8,253,230,32,in:device)
        place(label("F5 刷新等 Mac 端适配需要软件持续运行，默认暂停。",12),8,299,850,36,in:device)
        place(message,192,787,925,58)
        for (index,title,selector) in [(0,"写入键位",#selector(writeKeys)),(1,"写入灯效",#selector(writeLighting)),(2,"写入宏与键位",#selector(writeMacros))]{
            let write=button(title,selector);write.tag=index;write.isEnabled=false;write.toolTip=HardwareWritePolicy.reason;place(write,954,752,174,30);writeButtons.append(write)
        }
        profile=try? HardwareProfile.fromHardware(HardwareSnapshot.demo())
        connection.stringValue="预览配置 · 未连接键盘";message.stringValue="先读取 USB 配置，再点选按键编辑。点击写入键位后才会修改键盘。"
        loadLighting();refreshMacroPicker();loadSelectedAssignment();update();chooseTab(tabButtons[0])
    }
    @objc func openMacSettings(){(NSApp.delegate as? Adapter)?.showSettings()}
    @objc func chooseTab(_ sender:NSButton){
        guard let tabs=tabView,(0..<tabs.tabViewItems.count).contains(sender.tag) else{return}
        tabs.selectTabViewItem(at:sender.tag)
        for tab in tabButtons{tab.state=tab.tag==sender.tag ? .on:.off;tab.needsDisplay=true}
        let titles=["按键功能","灯效","宏","配置与备份","设备与诊断"]
        let descriptions=["点选一个按键，设置你习惯的功能。","选择内置模式，或为每个按键配色。","把连续的按键操作保存为一个动作。","保存配置，管理备份，迁移你的设置。","查看设备状态和 Mac 端适配选项。"]
        pageTitle.stringValue=titles[sender.tag];pageDescription.stringValue=descriptions[sender.tag]
        board.isHidden=sender.tag>=3;tabs.frame=NSRect(x:192,y:sender.tag>=3 ? 188:462,width:936,height:sender.tag>=3 ? 566:294)
        writeButtons.forEach{$0.isHidden=$0.tag != sender.tag}
        update()
    }
    var lightingTab:Bool {tabView?.selectedTabViewItem?.identifier as? String == "灯效"}
    @objc func selectKey(_ sender:KeyButton){
        selected=sender.spec.id
        if lightingTab && (lightMultiple.state == .on || NSApp.currentEvent?.modifierFlags.contains(.command)==true){
            if lightSelection.contains(selected){lightSelection.remove(selected)}else{lightSelection.insert(selected)}
        }else{lightSelection=[selected]}
        loadSelectedAssignment();update();loadLightColor()
    }
    func loadSelectedAssignment(){
        guard let key=keyboardLayout().first(where:{$0.id==selected}),let slot=CherryMatrix.slot(key),let profile else{return}
        let bytes=Array(profile.snapshot.keymap[slot*3..<slot*3+3])
        let presets:[[UInt8]]=[[0x20,13,6],[0x20,10,33],[0x20,8,21],[0x30,182,0],[0x30,205,0],[0x30,181,0],[0x20,0,0]]
        if let preset=presets.firstIndex(of:bytes){actionPicker.selectItem(at:preset+2)}else{
            actionPicker.selectItem(at:0)
            if bytes[0]==0x20 {
                actionPicker.selectItem(at:1)
                if let item=shortcutKeys.firstIndex(where:{$0.1==bytes[2]}){keyPicker.selectItem(at:item)}
                for (index,button) in modifiers.enumerated(){button.state=bytes[1] & [UInt8(0x88),0x11,0x44,0x22][index] == 0 ? .off:.on}
            }else{keyPicker.selectItem(at:0);modifiers.forEach{$0.state = .off}}
        }
        actionChanged()
    }
    func update(){
        writeButtons.forEach{$0.isEnabled=false}
        if !busy,let baseline,let profile,profile.snapshot.deviceInfo==baseline.deviceInfo,let plan=try? KeymapWriteAuthorization(baseline:baseline,keymap:profile.snapshot.keymap){writeButtons.first?.isEnabled = !plan.changedSlots.isEmpty;writeButtons.first?.toolTip="仅写键位表；灯效与宏区保留。"}
        for b in keyButtons{b.chosen=lightingTab ? lightSelection.contains(b.spec.id):b.spec.id==selected
            b.lightingColor=nil
            if lightingTab,let slot=CherryMatrix.slot(b.spec),let colors=profile?.snapshot.colors{b.lightingColor=NSColor(srgbRed:CGFloat(colors[slot*3])/255,green:CGFloat(colors[slot*3+1])/255,blue:CGFloat(colors[slot*3+2])/255,alpha:1)}
            if let slot=CherryMatrix.slot(b.spec),let p=profile,let original=baseline{
                if lightingTab,let colors=p.snapshot.colors,let previous=original.colors{b.mapped=colors[slot*3..<slot*3+3] != previous[slot*3..<slot*3+3]}else{b.mapped=p.snapshot.keymap[slot*3..<slot*3+3] != original.keymap[slot*3..<slot*3+3]}
            }else{b.mapped=false}}
        lightCount.stringValue="已选 \(lightSelection.count) 键"
        guard let key=keyboardLayout().first(where:{$0.id==selected})else{return}
        selectedLabel.stringValue=key.label
        if let slot=CherryMatrix.slot(key),let p=profile{
            recordLabel.stringValue="当前配置："+(p.macroBindings?[slot].map{"宏 · \($0)"} ?? CherryMatrix.describe(Array(p.snapshot.keymap[slot*3..<slot*3+3])))
        }else{recordLabel.stringValue="读取键盘后可查看此键配置"}
    }
    func loadLighting(){
        guard let profile else{return}
        let parameters=profile.snapshot.parameters
        modes[0].1=parameters[1];modePicker.item(at:0)?.title="保留当前模式（\(parameters[1])）";modePicker.selectItem(at:0)
        globalLightColor.color=NSColor(srgbRed:CGFloat(parameters[6])/255,green:CGFloat(parameters[7])/255,blue:CGFloat(parameters[8])/255,alpha:1)
        brightness.doubleValue=Double(parameters[2]);speed.doubleValue=Double(4-Int(parameters[3]));lightDirection.selectItem(at:0);lightRainbow.selectItem(at:0);loadLightColor()
    }
    var backupDirectory:URL{FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CherryMac/HardwareBackups")}
    @objc func readKeyboard(){readKeyboardThen()}
    func readKeyboardThen(_ completion:((HardwareSnapshot)->Void)? = nil){
        guard !busy else{return};busy=true;controls.forEach{$0.isEnabled=false};message.stringValue="正在读取 USB 配置…"
        queue.async{[weak self] in
            let result:Result<HardwareSnapshot,Error>=Result{
                let usb=try CherryUSB(),log=try? HardwareOperationLog(kind:"read")
                usb.trace=log?.trace
                do{let result=try usb.completeSnapshot();log?.record("phase","complete");return result}
                catch{log?.record("phase","failed");log?.record("error",error.localizedDescription);throw error}
            }
            DispatchQueue.main.async{guard let self else{return};self.busy=false;self.controls.forEach{$0.isEnabled=true};self.writeButtons.forEach{$0.isEnabled=false}
                switch result{case .success(let snapshot):
                    self.baseline=snapshot;self.profile=(try? HardwareProfile.fromHardware(snapshot)) ?? HardwareProfile(snapshot:snapshot)
                    self.connection.stringValue="USB 已连接 · 126 个固件键位 · 已读取键位、灯效与宏区"
                    self.loadLighting();self.refreshMacroPicker()
                    do{try FileManager.default.createDirectory(at:self.backupDirectory,withIntermediateDirectories:true)
                        let url=self.backupDirectory.appendingPathComponent("USB-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json")
                        try self.profile!.encoded().write(to:url,options:.atomic);self.message.stringValue=self.profile!.macroBindings==nil ? "读取并备份完成。原宏格式暂不支持编辑，原始宏区已保留。":"读取完成，已自动备份。可以点选键位、编辑灯效与宏。"}
                    catch{self.message.stringValue="读取完成，备份失败：\(error.localizedDescription)"}
                    self.loadSelectedAssignment();self.update()
                    completion?(snapshot)
                case .failure(let error):self.baseline=nil;self.connection.stringValue="USB 读取失败";self.message.stringValue=error.localizedDescription;self.update()}
            }
        }
    }
    @objc func writeKeys(){
        guard !busy,let draft=profile,let baseline else{message.stringValue="请先读取键盘，再编辑键位。";return}
        guard draft.snapshot.keymap != baseline.keymap else{message.stringValue="没有待写入的键位改动。";return}
        let plan:KeymapWriteAuthorization
        do{guard draft.snapshot.deviceInfo==baseline.deviceInfo else{throw HardwareError(message:"配置来自不同固件，请使用当前读取配置编辑。")};plan=try KeymapWriteAuthorization(baseline:baseline,keymap:draft.snapshot.keymap)}catch{message.stringValue=error.localizedDescription;return}
        let alert=NSAlert();alert.messageText="写入 \(plan.changedSlots.count) 个按键？"
        let names=keyboardLayout().filter{key in CherryMatrix.slot(key).map{plan.changedSlots.contains($0)} ?? false}.map{key in "\(key.label.replacingOccurrences(of:"\n",with:" / ")) → \(CherryMatrix.describe(Array(plan.expected.keymap[CherryMatrix.slot(key)!*3..<CherryMatrix.slot(key)!*3+3])))"}
        alert.informativeText=names.prefix(10).joined(separator:"\n")+(names.count>10 ? "\n另有 \(names.count-10) 个按键":"")+"\n\n请松开全部按键，写入时不要使用键盘。程序会先保存备份、检查释放并读回核对。灯效与宏区不会写入。"
        alert.addButton(withTitle:"开始写入");alert.addButton(withTitle:"返回编辑")
        alert.beginSheetModal(for:window!){[weak self] response in guard response == .alertFirstButtonReturn,let self else{return};self.performKeyWrite(draft: draft,baseline:baseline)}
    }
    func performKeyWrite(draft:HardwareProfile,baseline:HardwareSnapshot){
        guard !busy else{return}
        busy=true;controls.forEach{$0.isEnabled=false}
        message.stringValue="正在备份并写入键位，请松开全部按键，完成前不要使用键盘…"
        queue.async{[weak self] in
            var log:HardwareOperationLog?
            let result:Result<HardwareSnapshot,Error>=Result{let operation=try HardwareOperationLog(kind:"keymap");log=operation;return try CherryUSB().applyKeymap(draft.snapshot.keymap,baseline:baseline,log:operation)}
            DispatchQueue.main.async{guard let self else{return};self.busy=false;self.controls.forEach{$0.isEnabled=true};self.writeButtons.forEach{$0.isEnabled=false};self.actionChanged()
                if let path=log?.string("backup"){UserDefaults.standard.set(path,forKey:"hardware.lastKeyBackup")}
                switch result{
                case .success(let snapshot):
                    self.baseline=snapshot;var remaining=draft;remaining.snapshot.keymap=snapshot.keymap;self.profile=remaining
                    self.message.stringValue="键位已写入，读回校验通过。备份和操作日志已自动保存。计算器键保留已验证，其他映射以实际测试为准。"
                case .failure(let error):self.baseline=nil;self.connection.stringValue="需要重新读取键盘";self.message.stringValue=error.localizedDescription+(log.map{"\n日志：\($0.url.path)"} ?? "")
                }
                self.update()
            }
        }
    }
    @objc func writeMacros(){
        guard !busy,let draft=profile,let baseline else{message.stringValue="请先读取键盘。";return}
        let expected:HardwareSnapshot
        do{expected=try draft.resolvedMacros()}catch{message.stringValue=error.localizedDescription;return}
        guard expected.keymap != baseline.keymap || expected.macroData != baseline.macroData else{message.stringValue="没有待写入的宏或键位改动。";return}
        do{try HardwareWritePolicy.requireWrites()}catch{message.stringValue=error.localizedDescription;return}
        busy=true;controls.forEach{$0.isEnabled=false};message.stringValue="正在备份并写入宏与键位，请松开全部按键，完成前不要使用键盘…"
        queue.async{[weak self] in
            let result:Result<HardwareSnapshot,Error>=Result{try CherryUSB().writeMacroConfiguration(expected,baseline:baseline)}
            DispatchQueue.main.async{guard let self else{return};self.busy=false;self.controls.forEach{$0.isEnabled=true};self.writeButtons.forEach{$0.isEnabled=false};self.actionChanged()
                switch result{
                case .success(let snapshot):
                    self.baseline=snapshot;var remaining=draft;remaining.snapshot.keymap=snapshot.keymap;remaining.snapshot.macroData=snapshot.macroData;self.profile=remaining
                    self.message.stringValue="宏与键位已写入，读回校验通过。实体触发与断电保存仍待验证。";self.update()
                case .failure(let error):self.message.stringValue=error.localizedDescription
                }
            }
        }
    }
    @objc func writeLighting(){
        guard !busy, let draft=profile,let baseline else{message.stringValue="请先读取键盘，再编辑灯效。";return}
        do{try HardwareWritePolicy.requireWrites()}catch{message.stringValue=error.localizedDescription;return}
        busy=true;controls.forEach{$0.isEnabled=false};message.stringValue="正在备份并写入灯效…"
        queue.async{[weak self] in
            let result:Result<HardwareSnapshot,Error>=Result{try CherryUSB().writeLighting(draft.snapshot,baseline:baseline)}
            DispatchQueue.main.async{guard let self else{return};self.busy=false;self.controls.forEach{$0.isEnabled=true};self.writeButtons.forEach{$0.isEnabled=false}
                switch result{
                case .success(let snapshot):
                    self.baseline=snapshot;var remaining=draft;remaining.snapshot.parameters=snapshot.parameters;remaining.snapshot.colors=snapshot.colors;self.profile=remaining
                    self.message.stringValue="灯效已写入，读回校验通过。断电保存仍待验证。";self.update()
                case .failure(let error):self.message.stringValue=error.localizedDescription
                }
            }
        }
    }
    @objc func actionChanged(){keyPicker.isEnabled = !busy && actionPicker.indexOfSelectedItem==1;modifiers.forEach{$0.isEnabled = !busy && actionPicker.indexOfSelectedItem==1}}
    @objc func stageKey(){
        guard var p=profile,let key=keyboardLayout().first(where:{$0.id==selected}),let slot=CherryMatrix.slot(key)else{message.stringValue="请先读取键盘。";return}
        guard !["cherry","modR1"].contains(key.id) else{message.stringValue="此键由键盘内部处理，暂时保留原功能。";return}
        let record:[UInt8]
        switch actionPicker.indexOfSelectedItem{
        case 0:message.stringValue="\(key.label) 保留当前功能。";return
        case 2:record=[0x20,0x0D,6]
        case 3:record=[0x20,0x0A,33]
        case 4:record=[0x20,8,21]
        case 5:record=[0x30,182,0]
        case 6:record=[0x30,205,0]
        case 7:record=[0x30,181,0]
        case 8:record=[0x20,0,0]
        default:var mask:UInt8=0;for (i,m) in modifiers.enumerated() where m.state == .on{mask |= [UInt8(8),1,4,2][i]};record=[0x20,mask,shortcutKeys[max(0,keyPicker.indexOfSelectedItem)].1]
        }
        p.macroBindings?.removeValue(forKey:slot)
        p.snapshot.keymap.replaceSubrange(slot*3..<slot*3+3,with:record);profile=p;message.stringValue="已编辑 \(key.label)：\(CherryMatrix.describe(record))。尚未写入键盘。";update()
    }
    @objc func stageMacro(){
        do{guard var p=profile else{throw HardwareError(message:"请先读取或导入配置。")}
            let lines=macroText.string.split(separator:"\n",omittingEmptySubsequences:true)
            let steps=try lines.map{line -> KeyboardMacro.Step in
                let parts=line.split(whereSeparator:{$0.isWhitespace});guard parts.count>=3,let delay=Int(parts.last!),["按下","松开","down","up"].contains(String(parts[parts.count-2]))else{throw HardwareError(message:"宏格式错误：\(line)")}
                let name=parts.dropLast(2).joined(separator:" ")
                let usage:UInt8?
                if name.hasPrefix("HID:"){usage=UInt8(name.dropFirst(4))}else{usage=self.hidKeys.first(where:{$0.0.caseInsensitiveCompare(name) == .orderedSame})?.1}
                guard let usage else{throw HardwareError(message:"无法识别宏按键：\(name)")}
                return KeyboardMacro.Step(usage:usage,pressed:["按下","down"].contains(String(parts[parts.count-2])),delayMilliseconds:delay)}
            let macro=KeyboardMacro(name:macroName.stringValue,steps:steps);try macro.validate()
            if let index=p.macros.firstIndex(where:{$0.name==macro.name}){p.macros[index]=macro}else{p.macros.append(macro)}
            try p.validate();if p.macroBindings != nil{p.snapshot=try p.resolvedMacros()}
            profile=p;refreshMacroPicker(selected:macro.name);message.stringValue="宏已保存到编辑区，共 \(steps.count) 步。可分配到按键；当前硬件写入停用。";update()
        }catch{message.stringValue=error.localizedDescription}
    }
    func refreshMacroPicker(selected:String?=nil){macroPicker.removeAllItems();macroPicker.addItem(withTitle:"新建宏");macroPicker.addItems(withTitles:profile?.macros.map{$0.name} ?? []);if let selected{macroPicker.selectItem(withTitle:selected)}}
    @objc func chooseMacro(){
        guard macroPicker.indexOfSelectedItem>0,let profile else{macroName.stringValue="新宏";macroText.string="";return}
        let macro=profile.macros[macroPicker.indexOfSelectedItem-1];macroName.stringValue=macro.name
        macroText.string=macro.steps.map{step in "\(hidKeys.first(where:{$0.1==step.usage})?.0 ?? "HID:\(step.usage)") \(step.pressed ? "按下":"松开") \(step.delayMilliseconds)"}.joined(separator:"\n")
    }
    @objc func appendMacroKey(){
        guard let delay=Int(macroDelay.stringValue),(0...60000).contains(delay),let key=macroKey.titleOfSelectedItem else{message.stringValue="宏间隔须为 0…60000 毫秒。";return}
        macroText.string += (macroText.string.isEmpty || macroText.string.hasSuffix("\n") ? "":"\n") + "\(key) 按下 0\n\(key) 松开 \(delay)"
    }
    @objc func assignMacro(){
        do{guard var p=profile,macroPicker.indexOfSelectedItem>0,let key=keyboardLayout().first(where:{$0.id==selected}),let slot=CherryMatrix.slot(key)else{throw HardwareError(message:"请先保存并选择一个宏，再点选键盘按键。")}
            let name=p.macros[macroPicker.indexOfSelectedItem-1].name;try p.assignMacro(named:name,to:slot);profile=p;loadSelectedAssignment();update();message.stringValue="已把「\(name)」分配到 \(key.label)，尚未写入键盘。"
        }catch{message.stringValue=error.localizedDescription}
    }
    @objc func deleteMacro(){guard var p=profile,macroPicker.indexOfSelectedItem>0 else{return};do{let name=p.macros[macroPicker.indexOfSelectedItem-1].name;try p.removeMacro(named:name);profile=p;refreshMacroPicker();chooseMacro();update();message.stringValue="宏已从编辑区删除；关联按键设为禁用，尚未写入键盘。"}catch{message.stringValue=error.localizedDescription}}
    @objc func exportProfile(){guard let p=profile else{message.stringValue="请先读取或导入配置。";return};let panel=NSSavePanel();panel.nameFieldStringValue="CherryMac-键盘配置.json";panel.beginSheetModal(for:window!){[weak self] result in guard result == .OK,let url=panel.url else{return};do{try p.encoded().write(to:url,options:.atomic);self?.message.stringValue="配置已导出。"}catch{self?.message.stringValue=error.localizedDescription}}}
    func loadImport(_ data:Data)throws {
        guard !busy else{throw HardwareError(message:"请等待键盘操作完成。")}
        guard data.count<=1_000_000 else{throw HardwareError(message:"配置文件过大。")}
        let next:HardwareProfile;let summary:String
        if WindowsProfile.isOfficial(data){
            guard let baseline else{throw HardwareError(message:"导入 Windows 配置前，请先读取当前 USB 键盘，以保留原配置和宏区。")}
            let imported=try WindowsProfile.decode(data,baseline:baseline);next=imported.profile;summary=imported.summary
        }else{next=try HardwareProfile.decode(data);summary="配置已载入编辑区，尚未写入键盘。"}
        profile=next;message.stringValue=summary;loadLighting();refreshMacroPicker();loadSelectedAssignment();update()
    }
    @objc func importProfile(){
        let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        panel.beginSheetModal(for:window!){[weak self] result in
            guard result == .OK,let url=panel.url,let self else{return}
            do{try self.loadImport(Data(contentsOf:url))}catch{self.message.stringValue=error.localizedDescription}
        }
    }
    @objc func openBackups(){do{try FileManager.default.createDirectory(at:backupDirectory,withIntermediateDirectories:true);NSWorkspace.shared.open(backupDirectory)}catch{message.stringValue=error.localizedDescription}}
    @objc func restoreLastKeys(){
        guard !busy else{return}
        guard let url=lastKeyBackup else{message.stringValue="还没有本客户端写入前的按键备份。其他备份可用“导入配置”载入。";return}
        let saved:HardwareSnapshot
        do{saved=try HardwareProfile.decode(Data(contentsOf:url)).snapshot}catch{message.stringValue="备份无法读取：\(error.localizedDescription)";return}
        readKeyboardThen{[weak self] current in
            guard let self else{return}
            do{
                guard saved.deviceInfo==current.deviceInfo else{throw HardwareError(message:"备份的设备／固件信息不符，未恢复。")}
                _ = try KeymapWriteAuthorization(baseline:current,keymap:saved.keymap)
                guard var draft=self.profile else{return};draft.snapshot.keymap=saved.keymap
                self.profile=draft;self.loadSelectedAssignment();self.update();self.writeKeys()
            }catch{self.message.stringValue=error.localizedDescription}
        }
    }
    @objc func openLogs(){let directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CherryMac/HardwareLogs");do{try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);NSWorkspace.shared.open(directory)}catch{message.stringValue=error.localizedDescription}}
    func windowShouldClose(_ sender:NSWindow)->Bool{if busy{message.stringValue="键盘操作仍在进行，请等待完成或错误提示后关闭。";return false};return true}
    @objc func discardDraft(){guard let baseline else{return};profile=(try? HardwareProfile.fromHardware(baseline)) ?? HardwareProfile(snapshot:baseline);message.stringValue="已恢复到最近读取的配置。";loadLighting();refreshMacroPicker();loadSelectedAssignment();update()}
    @objc func installCalculator(){do{try CalculatorService.install();message.stringValue="已安装系统快捷操作。把目标键设为“打开系统计算器”，保存到编辑区后点击“写入键位”。"}catch{message.stringValue=error.localizedDescription}}
}
