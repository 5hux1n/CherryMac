import AppKit

final class HardwareCanvas: NSView {
    override var isFlipped:Bool {true}
    override func draw(_ dirtyRect:NSRect){NSColor.windowBackgroundColor.setFill();bounds.fill()}
}

final class HardwareWindowController: NSWindowController, NSTextFieldDelegate {
    let root = HardwareCanvas(frame:NSRect(x:0,y:0,width:1040,height:700))
    let board = FlippedView(frame:NSRect(x:87,y:120,width:866,height:260))
    let connection = NSTextField(labelWithString:"尚未读取键盘")
    let message = NSTextField(wrappingLabelWithString:"用 USB 数据线连接键盘并切到有线模式，然后读取配置。")
    let selectedLabel = NSTextField(labelWithString:"计算器")
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
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1040,height:700),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init(window:window)
        window.title="CherryMac · 键盘配置";window.minSize=NSSize(width:900,height:630);window.center()
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true;scroll.documentView=root;window.contentView=scroll
        build()
    }
    required init?(coder:NSCoder){fatalError()}
    func place(_ view:NSView,_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat,in parent:NSView?=nil){view.frame=NSRect(x:x,y:y,width:w,height:h);(parent ?? root).addSubview(view)}
    func label(_ title:String,_ size:CGFloat=13,_ weight:NSFont.Weight = .regular)->NSTextField{let l=NSTextField(wrappingLabelWithString:title);l.font = .systemFont(ofSize:size,weight:weight);return l}
    func button(_ title:String,_ selector:Selector)->NSButton{let b=NSButton(title:title,target:self,action:selector);controls.append(b);return b}
    func build(){
        place(label("MX 3.0S POKÉMON Wireless",24,.semibold),24,22,750,35)
        place(connection,24,65,675,23)
        place(button("读取键盘",#selector(readKeyboard)),900,25,112,30)
        place(label("点选按键，编辑配置。单键保持正方形；右上角四个按钮对应计算器和媒体控制。",12),24,96,960,20)
        root.addSubview(board)
        for spec in keyboardLayout(){let key=KeyButton(spec);key.hardwareConfigurable=true;if spec.id=="cherry"{key.title="CH"};key.target=self;key.action=#selector(selectKey(_:));board.addSubview(key);keyButtons.append(key)}
        let tabs=NSTabView();tabs.tabViewType = .noTabsNoBorder;tabView=tabs;place(tabs,24,436,988,185)
        for title in ["键位","灯效","宏","配置文件"]{let item=NSTabViewItem(identifier:title);item.label=title;item.view=FlippedView();tabs.addTabViewItem(item)}
        for (index,title) in ["键位","灯效","宏","配置文件"].enumerated(){
            let tab=NSButton(title:title,target:self,action:#selector(chooseTab(_:)));tab.tag=index;tab.bezelStyle = .rounded
            place(tab,24+CGFloat(index)*152,394,140,29);tabButtons.append(tab)
        }
        tabButtons.first?.bezelColor = .controlAccentColor
        let keys=tabs.tabViewItems[0].view!
        selectedLabel.font = .systemFont(ofSize:18,weight:.semibold)
        place(selectedLabel,18,16,210,28,in:keys);place(recordLabel,18,52,235,50,in:keys)
        place(label("设置为"),277,17,65,23,in:keys)
        actionPicker.addItems(withTitles:["保留当前功能","快捷键组合","打开系统计算器","框选区域截图","刷新 · ⌘R","上一曲","播放 / 暂停","下一曲","禁用"])
        actionPicker.target=self;actionPicker.action=#selector(actionChanged);controls.append(actionPicker)
        place(actionPicker,344,13,235,28,in:keys)
        keyPicker.addItems(withTitles:shortcutKeys.map{$0.0});controls.append(keyPicker);place(keyPicker,599,13,105,28,in:keys)
        for (i,m) in modifiers.enumerated(){controls.append(m);place(m,277+CGFloat(i%2)*176,54+CGFloat(i/2)*30,170,25,in:keys)}
        place(button("加入待写入配置",#selector(stageKey)),735,13,190,28,in:keys)
        place(label("计算器需先安装 macOS 快捷操作；由系统服务启动，实体键调用仍待验证。",12),277,124,640,30,in:keys)
        place(button("安装计算器快捷操作",#selector(installCalculator)),18,123,230,28,in:keys)
        buildLighting(tabs.tabViewItems[1].view!)
        let macros=tabs.tabViewItems[2].view!
        place(label("宏名称"),18,15,65,24,in:macros);controls.append(macroName);place(macroName,85,11,220,28,in:macros)
        macroPicker.addItem(withTitle:"新建宏");macroPicker.target=self;macroPicker.action=#selector(chooseMacro);controls.append(macroPicker);place(macroPicker,323,11,210,28,in:macros)
        place(button("删除",#selector(deleteMacro)),543,11,55,28,in:macros)
        let macroScroll=NSScrollView(frame:NSRect(x:18,y:52,width:570,height:108));macroScroll.hasVerticalScroller=true;macroScroll.borderType = .bezelBorder
        macroText.frame=NSRect(origin:.zero,size:macroScroll.contentSize);macroText.minSize=NSSize(width:0,height:macroScroll.contentSize.height);macroText.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        macroText.isVerticallyResizable=true;macroText.isHorizontallyResizable=false;macroText.autoresizingMask = .width;macroText.textContainer?.widthTracksTextView=true;macroText.textContainerInset=NSSize(width:6,height:6)
        macroScroll.documentView=macroText;macroText.isRichText=false;macroText.font = .monospacedSystemFont(ofSize:12,weight:.regular);macroText.string="A 按下 0\nA 松开 50";macros.addSubview(macroScroll)
        macroKey.addItems(withTitles:hidKeys.filter{$0.1 != 0}.map{$0.0});controls.append(macroKey);place(macroKey,614,11,122,28,in:macros)
        place(label("间隔 ms"),744,15,64,24,in:macros);controls.append(macroDelay);place(macroDelay,815,11,88,28,in:macros)
        place(button("添加按键",#selector(appendMacroKey)),614,52,135,30,in:macros)
        place(button("保存宏",#selector(stageMacro)),766,52,139,30,in:macros)
        place(button("分配到选中的键",#selector(assignMacro)),614,94,291,30,in:macros)
        place(label("实验性：执行一次。存储读写已验证，实体触发与断电保存待验证。",11),614,132,315,38,in:macros)
        let files=tabs.tabViewItems[3].view!
        place(button("导出配置…",#selector(exportProfile)),18,18,180,30,in:files)
        place(button("导入配置…",#selector(importProfile)),216,18,180,30,in:files)
        place(button("打开自动备份",#selector(openBackups)),414,18,180,30,in:files)
        place(button("撤销待写入改动",#selector(discardDraft)),612,18,265,30,in:files)
        place(label("USB 读取包含键位、灯效、逐键颜色与原始宏区。导入只载入编辑区，写入前会保留完整备份。",12),18,77,895,40,in:files)
        place(message,24,632,557,58)
        place(button("写入键位",#selector(writeKeys)),591,642,123,30)
        place(button("写入宏与键位",#selector(writeMacros)),725,642,153,30)
        place(button("写入灯效",#selector(writeLighting)),889,642,123,30)
        update()
    }
    @objc func chooseTab(_ sender:NSButton){tabView?.selectTabViewItem(at:sender.tag);for tab in tabButtons{tab.bezelColor=tab.tag==sender.tag ? .controlAccentColor:nil};update()}
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
        brightness.doubleValue=Double(parameters[2]);speed.doubleValue=Double(4-Int(parameters[3]));lightDirection.selectItem(at:0);lightRainbow.selectItem(at:0);loadLightColor()
    }
    var backupDirectory:URL{FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CherryMac/HardwareBackups")}
    @objc func readKeyboard(){
        guard !busy else{return};busy=true;controls.forEach{$0.isEnabled=false};message.stringValue="正在读取 USB 配置…"
        queue.async{[weak self] in
            let result:Result<HardwareSnapshot,Error>=Result{
                let usb=try CherryUSB();return try usb.completeSnapshot()
            }
            DispatchQueue.main.async{guard let self else{return};self.busy=false;self.controls.forEach{$0.isEnabled=true}
                switch result{case .success(let snapshot):
                    self.baseline=snapshot;self.profile=(try? HardwareProfile.fromHardware(snapshot)) ?? HardwareProfile(snapshot:snapshot)
                    self.connection.stringValue="USB 已连接 · 126 个固件键位 · 已读取键位、灯效与宏区"
                    self.loadLighting();self.refreshMacroPicker()
                    do{try FileManager.default.createDirectory(at:self.backupDirectory,withIntermediateDirectories:true)
                        let url=self.backupDirectory.appendingPathComponent("USB-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json")
                        try self.profile!.encoded().write(to:url,options:.atomic);self.message.stringValue=self.profile!.macroBindings==nil ? "读取并备份完成。原宏格式暂不支持编辑，原始宏区已保留。":"读取完成，已自动备份。可以点选键位、编辑灯效与宏。"}
                    catch{self.message.stringValue="读取完成，备份失败：\(error.localizedDescription)"}
                    self.loadSelectedAssignment();self.update()
                case .failure(let error):self.connection.stringValue="USB 读取失败";self.message.stringValue=error.localizedDescription}
            }
        }
    }
    @objc func writeKeys(){
        guard !busy,let draft=profile,let baseline else{message.stringValue="请先读取键盘，再编辑键位。";return}
        guard draft.snapshot.keymap != baseline.keymap else{message.stringValue="没有待写入的键位改动。";return}
        let newMacros=(0..<126).contains{slot in [UInt8(0x70),0x71].contains(draft.snapshot.keymap[slot*3]) && draft.snapshot.keymap[slot*3..<slot*3+3] != baseline.keymap[slot*3..<slot*3+3]}
        if newMacros && draft.snapshot.macroData != baseline.macroData {message.stringValue="此键位依赖新的宏，请点击「写入宏与键位」。";return}
        busy=true;controls.forEach{$0.isEnabled=false}
        message.stringValue="正在备份并写入键位，请松开全部按键，完成前不要使用键盘…"
        queue.async{[weak self] in
            let result:Result<HardwareSnapshot,Error>=Result{try CherryUSB().writeKeymap(draft.snapshot.keymap,baseline:baseline)}
            DispatchQueue.main.async{guard let self else{return};self.busy=false;self.controls.forEach{$0.isEnabled=true};self.actionChanged()
                switch result{
                case .success(let snapshot):
                    self.baseline=snapshot;var remaining=draft;remaining.snapshot.keymap=snapshot.keymap;self.profile=remaining
                    self.message.stringValue="键位已写入，读回校验通过。断电保存仍待验证。";self.update()
                case .failure(let error):self.message.stringValue=error.localizedDescription
                }
            }
        }
    }
    @objc func writeMacros(){
        guard !busy,let draft=profile,let baseline else{message.stringValue="请先读取键盘。";return}
        let expected:HardwareSnapshot
        do{expected=try draft.resolvedMacros()}catch{message.stringValue=error.localizedDescription;return}
        guard expected.keymap != baseline.keymap || expected.macroData != baseline.macroData else{message.stringValue="没有待写入的宏或键位改动。";return}
        busy=true;controls.forEach{$0.isEnabled=false};message.stringValue="正在备份并写入宏与键位，请松开全部按键，完成前不要使用键盘…"
        queue.async{[weak self] in
            let result:Result<HardwareSnapshot,Error>=Result{try CherryUSB().writeMacroConfiguration(expected,baseline:baseline)}
            DispatchQueue.main.async{guard let self else{return};self.busy=false;self.controls.forEach{$0.isEnabled=true};self.actionChanged()
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
        busy=true;controls.forEach{$0.isEnabled=false};message.stringValue="正在备份并写入灯效…"
        queue.async{[weak self] in
            let result:Result<HardwareSnapshot,Error>=Result{try CherryUSB().writeLighting(draft.snapshot,baseline:baseline)}
            DispatchQueue.main.async{guard let self else{return};self.busy=false;self.controls.forEach{$0.isEnabled=true}
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
            profile=p;refreshMacroPicker(selected:macro.name);message.stringValue="宏已保存，共 \(steps.count) 步。分配到按键后，可联合写入宏与键位。";update()
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
    @objc func importProfile(){let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false;panel.beginSheetModal(for:window!){[weak self] result in guard result == .OK,let url=panel.url else{return};do{let p=try HardwareProfile.decode(Data(contentsOf:url));self?.profile=p;self?.message.stringValue="配置已载入编辑区，尚未写入键盘。";self?.loadLighting();self?.refreshMacroPicker();self?.loadSelectedAssignment();self?.update()}catch{self?.message.stringValue=error.localizedDescription}}}
    @objc func openBackups(){do{try FileManager.default.createDirectory(at:backupDirectory,withIntermediateDirectories:true);NSWorkspace.shared.open(backupDirectory)}catch{message.stringValue=error.localizedDescription}}
    @objc func discardDraft(){guard let baseline else{return};profile=(try? HardwareProfile.fromHardware(baseline)) ?? HardwareProfile(snapshot:baseline);message.stringValue="已恢复到最近读取的配置。";loadLighting();refreshMacroPicker();loadSelectedAssignment();update()}
    @objc func installCalculator(){do{try CalculatorService.install();message.stringValue="已安装系统快捷操作：⌃⌥⌘C 打开计算器。键盘写入仍在验证。"}catch{message.stringValue=error.localizedDescription}}
}
