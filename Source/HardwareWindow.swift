import AppKit
import ApplicationServices

// Local editing only: no HID handle, global input hooks or permission requests.
final class MacroStepEditor:NSWindowController,NSTableViewDataSource,NSTableViewDelegate,NSTextFieldDelegate,NSWindowDelegate {
    struct KeyChoice{let name:String;let usage:UInt8;let kind:KeyboardMacro.Step.Kind?}
    var steps:[KeyboardMacro.Step]
    var delays:[String]
    let choices:[KeyChoice]
    let completion:([KeyboardMacro.Step]?)->Void
    let table=NSTableView()
    let insertion=NSPopUpButton()
    let message=NSTextField(wrappingLabelWithString:"每步等待在该事件执行后发生。完成编辑后采用，再保存宏；不会写入键盘。")
    var finished=false
    init(steps:[KeyboardMacro.Step],choices:[KeyChoice],completion:@escaping([KeyboardMacro.Step]?)->Void){
        self.steps=steps;self.delays=steps.map{String($0.delayMilliseconds)};self.choices=choices;self.completion=completion
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:780,height:510),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        super.init(window:window);window.title="编辑宏步骤";window.delegate=self
        let view=HardwareCanvas(frame:NSRect(x:0,y:0,width:780,height:510));window.contentView=view
        for (id,title,width) in [("number","步骤",48.0),("key","按键",305.0),("state","动作",130.0),("delay","事件后等待（毫秒）",210.0)]{
            let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier(id));column.title=title;column.width=width;table.addTableColumn(column)
        }
        table.delegate=self;table.dataSource=self;table.rowHeight=32;table.intercellSpacing=NSSize(width:8,height:3);table.allowsMultipleSelection=false
        let scroll=NSScrollView(frame:NSRect(x:18,y:18,width:744,height:346));scroll.hasVerticalScroller=true;scroll.borderType = .bezelBorder;scroll.documentView=table;view.addSubview(scroll)
        func button(_ title:String,_ action:Selector,_ x:CGFloat,_ width:CGFloat,tag:Int=0){let b=NSButton(title:title,target:self,action:action);b.frame=NSRect(x:x,y:378,width:width,height:30);b.tag=tag;view.addSubview(b)}
        button("添加按下／松开",#selector(addPair),18,160);button("删除",#selector(deleteStep),188,64)
        for (index,title) in ["置顶","上移","下移","置底"].enumerated(){button(title,#selector(moveStep),268+CGFloat(index)*76,68,tag:index)}
        insertion.addItems(withTitles:["末尾追加","所选步骤前插入","所选步骤后插入"]);insertion.frame=NSRect(x:588,y:378,width:174,height:30);insertion.setAccessibilityLabel("新增步骤的位置");view.addSubview(insertion)
        message.frame=NSRect(x:18,y:424,width:470,height:66);message.font = .systemFont(ofSize:12);view.addSubview(message)
        let cancel=NSButton(title:"取消",target:self,action:#selector(cancel));cancel.frame=NSRect(x:506,y:448,width:90,height:32);view.addSubview(cancel)
        let apply=NSButton(title:"采用步骤",target:self,action:#selector(apply));apply.frame=NSRect(x:608,y:448,width:152,height:32);view.addSubview(apply)
        table.reloadData()
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    func numberOfRows(in tableView:NSTableView)->Int{steps.count}
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int)->NSView?{
        guard steps.indices.contains(row),let id=column?.identifier.rawValue else{return nil}
        let step=steps[row]
        if id=="number"{let field=NSTextField(labelWithString:String(row+1));field.font = .monospacedDigitSystemFont(ofSize:13,weight:.regular);return field}
        if id=="key"{
            let picker=NSPopUpButton();picker.addItems(withTitles:choices.map{$0.name});picker.tag=row;picker.target=self;picker.action=#selector(keyChanged)
            if let index=choices.firstIndex(where:{$0.usage==step.usage && $0.kind==step.kind}){picker.selectItem(at:index)}else{picker.addItem(withTitle:"HID \(step.usage)");picker.selectItem(at:choices.count)}
            picker.setAccessibilityLabel("步骤 \(row+1) 按键");return picker
        }
        if id=="state"{let picker=NSPopUpButton();picker.addItems(withTitles:["按下","松开"]);picker.selectItem(at:step.pressed ? 0:1);picker.tag=row;picker.target=self;picker.action=#selector(stateChanged);picker.setAccessibilityLabel("步骤 \(row+1) 动作");return picker}
        let field=NSTextField(string:delays[row]);field.tag=row;field.delegate=self;field.setAccessibilityLabel("步骤 \(row+1) 事件后等待毫秒");return field
    }
    func controlTextDidChange(_ notification:Notification){guard let field=notification.object as? NSTextField,delays.indices.contains(field.tag) else{return};delays[field.tag]=field.stringValue;message.stringValue="编辑完成后采用步骤；保存时检查按下与松开是否配对。"}
    @objc func keyChanged(_ picker:NSPopUpButton){guard steps.indices.contains(picker.tag),choices.indices.contains(picker.indexOfSelectedItem) else{return};let key=choices[picker.indexOfSelectedItem];steps[picker.tag].usage=key.usage;steps[picker.tag].kind=key.kind}
    @objc func stateChanged(_ picker:NSPopUpButton){guard steps.indices.contains(picker.tag) else{return};steps[picker.tag].pressed=picker.indexOfSelectedItem==0}
    func select(_ index:Int){table.reloadData();if steps.indices.contains(index){table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false);table.scrollRowToVisible(index)}}
    @objc func addPair(){
        window?.makeFirstResponder(nil)
        guard steps.count<=254 else{message.stringValue="最多 256 个事件，请先删除部分步骤。";return}
        guard insertion.indexOfSelectedItem==0 || steps.indices.contains(table.selectedRow) else{message.stringValue="请先选中插入位置对应的步骤。";return}
        let key=steps.indices.contains(table.selectedRow) ? steps[table.selectedRow]:.init(usage:4,pressed:true,delayMilliseconds:50)
        let index=insertion.indexOfSelectedItem==0 ? steps.count:table.selectedRow+(insertion.indexOfSelectedItem==2 ? 1:0)
        steps.insert(contentsOf:[.init(usage:key.usage,pressed:true,delayMilliseconds:50,kind:key.kind),.init(usage:key.usage,pressed:false,delayMilliseconds:0,kind:key.kind)],at:index)
        delays.insert(contentsOf:["50","0"],at:index);select(index);message.stringValue="已插入按下／松开；原步骤和等待保留，采用时检查事件配对。"
    }
    @objc func deleteStep(){window?.makeFirstResponder(nil);let row=table.selectedRow;guard steps.indices.contains(row) else{return};steps.remove(at:row);delays.remove(at:row);select(min(row,steps.count-1))}
    @objc func moveStep(_ sender:NSButton){
        window?.makeFirstResponder(nil);let row=table.selectedRow;guard steps.indices.contains(row),(0...3).contains(sender.tag) else{return}
        let next=[0,max(0,row-1),min(steps.count-1,row+1),steps.count-1][sender.tag]
        guard next != row else{return};steps.insert(steps.remove(at:row),at:next);delays.insert(delays.remove(at:row),at:next);select(next)
    }
    @objc func apply(){
        window?.makeFirstResponder(nil)
        do{var result=steps
            for index in result.indices{guard let delay=Int(delays[index]),(0...60000).contains(delay) else{throw HardwareError(message:"步骤 \(index+1) 的等待须为 0…60000 毫秒整数。")};result[index].delayMilliseconds=delay}
            try KeyboardMacro(name:"步骤编辑",steps:result).validate();finish(result)
        }catch{message.stringValue=error.localizedDescription}
    }
    func finish(_ result:[KeyboardMacro.Step]?){guard !finished else{return};finished=true;if let window{window.sheetParent?.endSheet(window);window.orderOut(nil)};completion(result)}
    @objc func cancel(){finish(nil)}
    func windowShouldClose(_ sender:NSWindow)->Bool{cancel();return false}
}

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

// Edits one text binding in memory. No HID access or input monitor.
final class HostTextEditor:NSWindowController,NSWindowDelegate {
    let source:Data
    let factory:[UInt8]
    let choices:[(String,Int)]
    let completion:(Data?)->Void
    let key=NSPopUpButton(),name=NSTextField(string:"文本"),text=NSTextView()
    let status=NSTextField(wrappingLabelWithString:"采用后仅修改文本配置；返回文本页核对安装才会写入键盘。")
    let remove=NSButton(title:"解除并恢复默认",target:nil,action:nil)
    var finished=false
    init(source:Data,factory:[UInt8],selected:Int?,completion:@escaping(Data?)->Void)throws {
        self.source=source;self.factory=factory;self.completion=completion
        _ = try WindowsProfile.templateRoot(source)
        choices=try keyboardLayout().compactMap{spec in
            guard let slot=CherryMatrix.slot(spec),KeymapWriteAuthorization.editableSlots.contains(slot),try WindowsProfile.resolveHostTextTrigger(eventValue:0x700+slot,factoryKeymap:factory) != nil else{return nil}
            return (spec.label.replacingOccurrences(of:"\n",with:" / "),slot)
        }
        guard !choices.isEmpty else{throw HardwareError(message:"默认表中没有可编辑的文本按键。")}
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:700,height:500),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        super.init(window:window);window.title="编辑文本绑定";window.delegate=self
        let view=HardwareCanvas(frame:NSRect(x:0,y:0,width:700,height:500));window.contentView=view
        func place(_ child:NSView,_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat){child.frame=NSRect(x:x,y:y,width:w,height:h);view.addSubview(child)}
        place(NSTextField(labelWithString:"按键"),20,24,65,25);key.addItems(withTitles:choices.map{$0.0});key.target=self;key.action=#selector(selectKey);place(key,90,20,240,28)
        place(NSTextField(labelWithString:"名称"),20,69,65,25);place(name,90,65,590,28)
        let scroll=NSScrollView(frame:NSRect(x:20,y:114,width:660,height:240));scroll.hasVerticalScroller=true;scroll.borderType = .bezelBorder
        text.frame=NSRect(origin:.zero,size:scroll.contentSize);text.isRichText=false;text.isVerticallyResizable=true;text.autoresizingMask = .width;text.textContainer?.widthTracksTextView=true;text.font = .systemFont(ofSize:14);text.textContainerInset=NSSize(width:10,height:10);scroll.documentView=text;view.addSubview(scroll)
        place(status,20,366,660,52)
        remove.target=self;remove.action=#selector(removeTextBinding);place(remove,20,438,180,30)
        place(NSButton(title:"取消",target:self,action:#selector(cancel)),424,438,100,30)
        place(NSButton(title:"采用文本绑定",target:self,action:#selector(apply)),540,438,140,30)
        if let selected,let index=choices.firstIndex(where:{$0.1==selected}){key.selectItem(at:index)}
        selectKey()
    }
    required init?(coder:NSCoder){fatalError()}
    @objc func selectKey(){
        name.stringValue="文本";text.string="";remove.isEnabled=false
        do{let root=try WindowsProfile.templateRoot(source),slot=choices[key.indexOfSelectedItem].1
            guard let trigger=try WindowsProfile.resolveHostTextTrigger(eventValue:0x700+slot,factoryKeymap:factory),let keys=root["KeyList"] as? [[String:Any]],let actions=root["ActionInfo"] as? [[String:Any]] else{return}
            let item=keys[trigger.logicalIndex]
            if try WindowsProfile.integer(item["ActionLink"] ?? 0,"ActionLink",range:0...1)==1 {
                let index=try WindowsProfile.integer(item["ActionLinkIndex"],"ActionLinkIndex",range:0...max(0,actions.count-1))
                guard actions.indices.contains(index) else{throw HardwareError(message:"动作引用无效。")}
                if try WindowsProfile.integer(actions[index]["ActionType"],"ActionType",range:0...4)==3 {let plan=try WindowsProfile.HostTextPlan(action:actions[index]);name.stringValue=plan.name;text.string=plan.originalText;remove.isEnabled=true}
            }
        }catch{status.stringValue=error.localizedDescription}
    }
    @objc func apply(){edit(text.string)}
    @objc func removeTextBinding(){edit(nil)}
    private func edit(_ value:String?){do{let data=try WindowsProfile.editHostText(source,factoryKeymap:factory,physicalSlot:choices[key.indexOfSelectedItem].1,text:value,name:name.stringValue);finish(data)}catch{status.stringValue=error.localizedDescription}}
    @objc func cancel(){finish(nil)}
    func finish(_ data:Data?){guard !finished else{return};finished=true;if let window{window.sheetParent?.endSheet(window);window.orderOut(nil)};completion(data)}
    func windowShouldClose(_ sender:NSWindow)->Bool{cancel();return false}
}

final class HardwareWindowController: NSWindowController, NSTextFieldDelegate, NSTextViewDelegate, NSWindowDelegate {
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
    let mediaPicker = NSPopUpButton()
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
    #if CHERRY_LIGHTING_TEST
    var lightingAcceptance:LightingAcceptanceWindow?
    #endif
    let modifiers = [NSButton(checkboxWithTitle:"⌘ Command",target:nil,action:nil),NSButton(checkboxWithTitle:"⌃ Control",target:nil,action:nil),NSButton(checkboxWithTitle:"⌥ Option",target:nil,action:nil),NSButton(checkboxWithTitle:"⇧ Shift",target:nil,action:nil)]
    let macroName = NSTextField(string:"新宏")
    let macroText = NSTextView()
    let macroPicker = NSPopUpButton()
    let macroKey = NSPopUpButton()
    let macroDelay = NSTextField(string:"50")
    let macroPlayback=NSPopUpButton()
    let macroRepeat=NSTextField(string:"1")
    let macroSummary=NSTextField(wrappingLabelWithString:"")
    let queue = DispatchQueue(label:"local.cherrymac.hardware")
    var keyButtons:[KeyButton] = []
    var tabButtons:[NSButton]=[]
    var tabView:NSTabView?
    var selected = "calculator"
    var profile:HardwareProfile?
    var baseline:HardwareSnapshot?
    var baselineLightingMapping:LightingMappingContext?
    var baselineWasRead=false
    var macroRecordingSheet:MacroRecordingSheet?
    var macroStepEditor:MacroStepEditor?
    var recordingPreference:KeyboardMacro.RecordingDelay?
    var currentMacroOperation:HardwareOperationLog?
    var macroCancellationButton:NSButton?
    #if CHERRY_MACRO_PRODUCT
    var hostTextJSON:Data?
    let hostTextStore=HostTextConfigurationStore()
    var hostTextEditor:HostTextEditor?
    var hostTextBridge:HostTextBridgeHTTP?
    var hostTextBridgeSession:HostTextBridgeSession?
    var hostTextBridgeTimer:Timer?
    var hostTextBridgeOwnsText=false
    let hostTextFile=NSTextField(wrappingLabelWithString:"尚未选择文本配置")
    let hostTextState=NSTextField(wrappingLabelWithString:"文本服务未开启")
    lazy var hostTextService=HostTextService(onState:{[weak self] state in self?.hostTextState.stringValue=state})
    #endif
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
    let mouseMacroKeys:[(String,UInt8)] = [("鼠标左键",1),("鼠标右键",2),("鼠标中键",4),("鼠标后退",8),("鼠标前进",16)]
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
        #if CHERRY_MACRO_PRODUCT
        place(label("开发预览：按键、宏与文本绑定分别写入；灯效写入暂缓，完整成品验收尚未完成。",12),192,140,925,24)
        #else
        place(label("按键可独立写入；灯效和宏可编辑、保存，实体写入暂缓。",12),192,140,925,24)
        #endif
        board.frame.origin=NSPoint(x:225,y:178);root.addSubview(board)
        for spec in keyboardLayout(){let key=KeyButton(spec);key.hardwareConfigurable=true;if spec.id=="cherry"{key.title="CH"};key.target=self;key.action=#selector(selectKey(_:));board.addSubview(key);keyButtons.append(key)}
        let tabs=NSTabView();tabs.tabViewType = .noTabsNoBorder;tabView=tabs;place(tabs,192,462,936,294)
        var titles=["键位","灯效","宏","配置与备份","设备与诊断"]
        #if CHERRY_MACRO_PRODUCT
        titles.append("文本")
        #endif
        titles.append("设备设置")
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
        actionPicker.addItems(withTitles:["保留当前功能","快捷键组合","打开系统计算器","框选区域截图","刷新 · ⌘R","上一曲","播放 / 暂停","下一曲","禁用","多媒体功能","打开 Finder · Mac 快捷操作","打开邮件 · Mac 快捷操作","打开音乐 · Mac 快捷操作"])
        actionPicker.target=self;actionPicker.action=#selector(actionChanged);controls.append(actionPicker)
        place(actionPicker,378,8,235,28,in:keys)
        place(label("快捷键主键"),282,57,95,23,in:keys)
        keyPicker.addItems(withTitles:shortcutKeys.map{$0.0});controls.append(keyPicker);place(keyPicker,378,53,155,28,in:keys)
        for (i,m) in modifiers.enumerated(){controls.append(m);place(m,282+CGFloat(i%2)*196,99+CGFloat(i/2)*31,185,25,in:keys)}
        place(label("多媒体功能"),650,12,125,23,in:keys)
        for index in WindowsProfile.visibleMediaIndices{mediaPicker.addItem(withTitle:WindowsProfile.mediaNames[index]);mediaPicker.lastItem?.tag=index}
        controls.append(mediaPicker);place(mediaPicker,650,48,245,28,in:keys)
        place(label("媒体键的响应取决于系统与当前应用。\n应用启动可安装 Mac 快捷操作，\n保存到编辑区后需单独写入键位。",12),650,91,245,80,in:keys)
        place(button("安装并设置 Mac 启动",#selector(installApplicationShortcut)),650,182,245,30,in:keys)
        place(button("保存到编辑区",#selector(stageKey)),282,182,186,30,in:keys)
        place(button("安装计算器快捷操作",#selector(installCalculator)),8,161,230,30,in:keys)
        place(label("系统计算器使用 macOS 快捷操作。\n安装后可把计算器键设置为 ⌃⌥⌘C。",12),8,210,236,60,in:keys)
        buildLighting(tabs.tabViewItems[1].view!)
        let macros=tabs.tabViewItems[2].view!
        place(label("已保存的宏"),8,12,100,24,in:macros)
        macroPicker.addItem(withTitle:"新建宏");macroPicker.target=self;macroPicker.action=#selector(chooseMacro);controls.append(macroPicker);place(macroPicker,116,8,226,28,in:macros)
        place(button("删除宏",#selector(deleteMacro)),359,8,90,28,in:macros)
        place(button("复制",#selector(copyMacro)),456,8,64,28,in:macros)
        place(button("清空",#selector(clearMacros)),527,8,64,28,in:macros)
        place(label("名称"),8,57,90,24,in:macros);controls.append(macroName);place(macroName,116,53,333,28,in:macros)
        macroSummary.font = .systemFont(ofSize:11);macroSummary.textColor = .secondaryLabelColor
        place(macroSummary,463,45,412,51,in:macros)
        macroName.delegate=self;macroRepeat.delegate=self;macroText.delegate=self
        let macroScroll=NSScrollView(frame:NSRect(x:8,y:99,width:552,height:120));macroScroll.hasVerticalScroller=true;macroScroll.borderType = .bezelBorder
        macroText.frame=NSRect(origin:.zero,size:macroScroll.contentSize);macroText.minSize=NSSize(width:0,height:macroScroll.contentSize.height);macroText.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        macroText.isVerticallyResizable=true;macroText.isHorizontallyResizable=false;macroText.autoresizingMask = .width;macroText.textContainer?.widthTracksTextView=true;macroText.textContainerInset=NSSize(width:10,height:10)
        macroText.toolTip="每行：按键、按下／松开、事件后等待毫秒。";macroScroll.documentView=macroText;macroText.isRichText=false;macroText.font = .monospacedSystemFont(ofSize:13,weight:.regular);macroText.string="A 按下 50\nA 松开 0";macros.addSubview(macroScroll)
        for (index,title) in ["置顶","上移","下移","置底"].enumerated(){let move=button(title,#selector(moveMacroStep));move.tag=index;place(move,8+CGFloat(index)*82,224,76,28,in:macros)}
        place(button("点选编辑步骤…",#selector(editMacroSteps)),346,224,210,28,in:macros)
        place(label("添加按键"),593,12,110,24,in:macros)
        macroKey.addItems(withTitles:(hidKeys.filter{$0.1 != 0}+mouseMacroKeys).map{$0.0});controls.append(macroKey);place(macroKey,707,8,168,28,in:macros)
        place(label("按住（毫秒）"),593,57,110,24,in:macros);controls.append(macroDelay);place(macroDelay,707,53,168,28,in:macros)
        place(button("添加按下与松开",#selector(appendMacroKey)),593,99,282,30,in:macros)
        place(button("保存宏",#selector(stageMacro)),593,144,282,30,in:macros)
        place(button("分配到所选键",#selector(assignMacro)),593,189,139,30,in:macros)
        place(button("解除所选键绑定",#selector(unassignMacro)),736,189,139,30,in:macros)
        macroPlayback.addItems(withTitles:["指定执行次数","按住持续","再次按键停止"]);macroPlayback.target=self;macroPlayback.action=#selector(playbackChanged);controls.append(macroPlayback)
        place(label("执行方式"),8,262,95,24,in:macros);place(macroPlayback,116,258,170,28,in:macros)
        place(label("次数"),306,262,55,24,in:macros);controls.append(macroRepeat);place(macroRepeat,370,258,80,28,in:macros)
        place(button("录制操作…",#selector(recordMacro)),593,233,282,30,in:macros)
        let files=tabs.tabViewItems[3].view!
        place(label("配置文件",20,.semibold),8,12,850,30,in:files)
        place(label("导入到编辑区，或把当前配置保存成文件。",13),8,52,850,26,in:files)
        place(button("导入配置…",#selector(importProfile)),8,94,180,32,in:files)
        place(button("导出配置…",#selector(exportProfile)),208,94,180,32,in:files)
        place(button("检查灯效恢复记录…",#selector(inspectLightingRecovery)),708,94,190,32,in:files)
        #if CHERRY_MACRO_PRODUCT
        place(button("导出 Windows 配置草稿…",#selector(exportWindowsProfile)),408,94,280,32,in:files)
        #else
        place(button("导出 Windows 配置草稿…",#selector(exportWindowsProfile)),408,94,280,32,in:files)
        #endif
        place(label("备份与撤销",17,.semibold),8,160,850,27,in:files)
        place(button("打开自动备份",#selector(openBackups)),8,205,180,32,in:files)
        place(button("撤销编辑区修改",#selector(discardDraft)),208,205,210,32,in:files)
        place(button("恢复最近按键备份",#selector(restoreLastKeys)),438,205,222,32,in:files)
        #if CHERRY_MACRO_PRODUCT
        place(button("恢复最近宏写入",#selector(restoreLastMacros)),678,205,195,32,in:files)
        #endif
        #if CHERRY_MACRO_PRODUCT
        place(label("Windows 导出需要已导入的官方模板，合并键位、宏和文本页选中的定义。同一个键若有键位修改与文本绑定，请先解除冲突。导出包含灯效草稿；自定义配色需官方原始颜色表，内置模式可使用没有逐键表的模板。设备设置沿用模板；导入和导出不修改键盘。",12),8,261,850,62,in:files)
        #else
        place(label("支持 CherryMac 配置与本型号 Windows JSON。Windows 导出先导入官方模板，包含键位、宏与当前灯效草稿；设备设置沿用模板。导入和撤销不修改键盘。",12),8,261,850,62,in:files)
        #endif
        place(label("官方默认配置",17,.semibold),8,354,850,28,in:files)
        place(button("载入官方默认草稿…",#selector(importDefaultTemplate)),8,401,260,32,in:files)
        place(label("选择 Windows 安装目录 DefaultData 中的 DefaultData0～4.json，载入本型号默认键位、灯效与文件设置。会替换编辑区；原始宏存储保留。这里只准备草稿，完整恢复默认尚未开放。",12),290,392,570,78,in:files)
        let device=tabs.tabViewItems[4].view!
        place(label("设备与诊断",20,.semibold),8,12,850,30,in:device)
        place(label("MX 3.0S Pokémon Wireless\n通过 USB 数据线连接，并切换到有线模式。",13),8,61,850,56,in:device)
        #if CHERRY_MACRO_PRODUCT
        let scopeDescription="宏模块开发预览：按键与宏分别写入，自动备份并完整读回。灯效写入暂缓。\n宏产品流程尚待统一实机验收；Win 锁、回报率等设备设置继续核对。"
        #else
        let scopeDescription="仅开放按键写入，自动备份、逐包检查释放并完整读回。灯效与宏写入暂缓。\nWin 锁、6 键／全键模式、回报率等设置会在协议确认后加入。"
        #endif
        place(label(scopeDescription,13),8,148,850,70,in:device)
        place(button("打开操作日志",#selector(openLogs)),8,253,180,32,in:device)
        let settings=tabs.tabViewItems.last!.view!
        place(label("设备设置",20,.semibold),8,12,850,30,in:settings)
        place(label("官方配置草稿",17,.semibold),8,69,850,28,in:settings)
        place(label("先导入 Windows 官方 JSON，再编辑 USB 回报率。修改会保存在配置与备份文件中；目前尚未写入键盘。无线回报率、Win 锁、键模式与重复设置保留原模板值，发送接口仍在核对。",13),8,109,850,70,in:settings)
        place(button("编辑官方回报率草稿…",#selector(editPollingDraft)),8,198,260,32,in:settings)
        place(label("Mac 端适配",17,.semibold),8,272,850,28,in:settings)
        place(label("F5 刷新等 Mac 端适配需要软件持续运行，默认暂停。它们不会保存到键盘；需要实体 F5 输出 ⌘R 时，可在按键页设置并写入。",13),8,312,850,60,in:settings)
        place(button("打开 Mac 端适配设置",#selector(openMacSettings)),8,397,260,32,in:settings)
        #if CHERRY_MACRO_PRODUCT
        let text=tabs.tabViewItems[5].view!
        place(label("文本快捷输入",20,.semibold),8,12,850,30,in:text)
        place(label("选择 Windows 官方导出的文本配置，启用后在目标应用按对应键输入文本。此功能需要 CherryMac 持续运行及辅助功能权限。",13),8,59,850,60,in:text)
        place(button("选择官方文本配置…",#selector(chooseHostTextProfile)),8,137,230,32,in:text)
        place(button("载入已保存配置",#selector(loadSavedHostText)),258,137,180,32,in:text)
        place(button("导出文本配置…",#selector(exportHostText)),458,137,180,32,in:text)
        place(hostTextFile,8,187,650,48,in:text)
        place(button("编辑文本绑定…",#selector(editHostText)),678,187,195,32,in:text)
        place(button("启用文本服务",#selector(startHostTextService)),8,257,180,32,in:text)
        place(button("停止",#selector(stopHostTextService)),208,257,100,32,in:text)
        place(button("查看最近日志",#selector(openHostTextLog)),328,257,180,32,in:text)
        place(hostTextState,8,312,850,64,in:text)
        place(button("安装文本绑定…",#selector(installHostText)),8,393,210,32,in:text)
        place(button("恢复最近文本安装…",#selector(restoreHostText)),238,393,240,32,in:text)
        place(button("导出文本恢复记录…",#selector(exportHostTextRecords)),8,438,230,32,in:text)
        place(button("导入文本恢复记录…",#selector(importHostTextRecords)),258,438,230,32,in:text)
        place(button("网页联动…",#selector(configureHostTextBridge)),528,438,180,32,in:text)
        place(label("开发预览，尚待统一真机验收。安装会显示改动并保存完整备份；只修改文本绑定键。恢复后服务保持关闭。读取、写入或重连后需重新启用服务。恢复记录可在 Mac 与网页间导入；已有不同记录保留。",12),8,490,850,62,in:text)
        #endif
        place(message,192,787,925,58)
        for (index,title,selector) in [(0,"写入键位",#selector(writeKeys)),(1,"写入灯效",#selector(writeLighting)),(2,"写入宏与绑定键",#selector(writeMacros))]{
            let write=button(title,selector);write.tag=index;write.isEnabled=false;write.toolTip=HardwareWritePolicy.reason;place(write,954,752,174,30);writeButtons.append(write)
        }
        #if CHERRY_MACRO_PRODUCT
        let cancel=button("停止发送 · 保留恢复记录",#selector(cancelMacroOperation));place(cancel,192,752,245,30);cancel.isHidden=true;macroCancellationButton=cancel
        #endif
        profile=try? HardwareProfile.fromHardware(HardwareSnapshot.demo())
        connection.stringValue="预览配置 · 未连接键盘";message.stringValue="先读取 USB 配置，再点选按键编辑。点击写入键位后才会修改键盘。"
        loadLighting();refreshMacroPicker();loadSelectedAssignment();update();chooseTab(tabButtons[0])
    }
    func suspendHostTextForConfiguration(){
        #if CHERRY_MACRO_PRODUCT
        hostTextBridgeOwnsText=false
        let shutdown=hostTextService.stopForConfiguration()
        hostTextState.stringValue="文本服务已停止"
        queue.async{shutdown()}
        #endif
    }
    #if CHERRY_MACRO_PRODUCT
    func loadHostTextProfile(_ data:Data,name:String)throws {
        guard !busy,macroRecordingSheet==nil else{throw HardwareError(message:"请先完成键盘操作或宏录制。")}
        let root=try WindowsProfile.templateRoot(data)
        guard let actions=root["ActionInfo"] as? [[String:Any]] else{throw HardwareError(message:"配置缺少动作列表。")}
        var count=0
        for action in actions {
            let type=try WindowsProfile.integer(action["ActionType"],"ActionType",range:0...4)
            if type==3 {let plan=try WindowsProfile.HostTextPlan(action:action);if plan.marker != nil{count += 1}}
        }
        suspendHostTextForConfiguration()
        hostTextJSON=data;hostTextFile.stringValue="\(name) · \(count) 个文本动作"
    }
    @objc func chooseHostTextProfile(){
        guard !busy,macroRecordingSheet==nil,let window else{return}
        let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        panel.beginSheetModal(for:window){[weak self] result in
            guard result == .OK,let self,let url=panel.url else{return}
            do{try self.loadHostTextProfile(Data(contentsOf:url),name:url.lastPathComponent)}catch{self.hostTextState.stringValue=error.localizedDescription}
        }
    }
    @objc func startHostTextService(){
        guard !busy,macroRecordingSheet==nil,window?.attachedSheet==nil else{hostTextState.stringValue="请先完成当前操作。";return}
        guard let data=hostTextJSON else{hostTextState.stringValue="请先选择官方文本配置。";return}
        do{try hostTextService.start(officialJSON:data)}catch{hostTextState.stringValue=error.localizedDescription}
    }
    @objc func loadSavedHostText(){
        guard !busy,macroRecordingSheet==nil else{return}
        suspendHostTextForConfiguration();busy=true;controls.forEach{$0.isEnabled=false}
        let store=hostTextStore
        queue.async{[weak self] in
            let result=Result<Data?,Error>{try store.activeConfiguration()}
            DispatchQueue.main.async{guard let self else{return};self.busy=false;self.controls.forEach{$0.isEnabled=true};self.update()
                do{if let data=try result.get(){try self.loadHostTextProfile(data,name:"已保存文本配置")}else{self.hostTextState.stringValue="没有已安装并保存的文本配置。"}}catch{self.hostTextState.stringValue=error.localizedDescription}
            }
        }
    }
    @objc func exportHostText(){
        guard !busy,let data=hostTextJSON,let window else{hostTextState.stringValue="请先选择文本配置。";return}
        let panel=NSSavePanel();panel.nameFieldStringValue="CherryMac-文本配置.json"
        panel.beginSheetModal(for:window){[weak self] response in
            guard response == .OK,let url=panel.url else{return}
            do{try data.write(to:url,options:.atomic);self?.hostTextState.stringValue="文本配置已导出。"}catch{self?.hostTextState.stringValue=error.localizedDescription}
        }
    }
    @objc func configureHostTextBridge(){
        guard !busy,macroRecordingSheet==nil,window?.attachedSheet==nil,let window else{return}
        let alert=NSAlert();alert.messageText="网页联动"
        alert.informativeText="开启后，把联动码粘贴到网页文本页。网页可启停 Mac 文本服务；配置操作前会等待服务释放 USB。联动码仅本次运行有效。"
        let enabled=hostTextBridge != nil
        alert.addButton(withTitle:enabled ? "复制联动码":"开启并复制联动码");alert.addButton(withTitle:enabled ? "关闭联动":"取消")
        if enabled{alert.addButton(withTitle:"取消")}
        alert.beginSheetModal(for:window){[weak self] response in
            guard let self else{return}
            if response == .alertFirstButtonReturn {
                do{
                    if self.hostTextBridge==nil {
                        let session=HostTextBridgeSession();self.hostTextBridgeSession=session
                        let server=try HostTextBridgeHTTP(handler:{[weak self] request,completion in Task{@MainActor [weak self] in
                            guard let self else{completion(HostTextBridgeRequest.response(status:503));return};self.handleHostTextBridge(request,completion:completion)
                        }},onState:{[weak self] ready,message in Task{@MainActor [weak self] in
                            guard let self,self.hostTextBridgeSession===session else{return}
                            if !ready{self.stopHostTextBridge()};self.hostTextState.stringValue=message
                        }})
                        self.hostTextBridge=server;server.start()
                        let timer=Timer(timeInterval:15,repeats:true){[weak self] _ in Task{@MainActor [weak self] in self?.expireHostTextBridge()}}
                        self.hostTextBridgeTimer=timer;RunLoop.main.add(timer,forMode:.common)
                    }
                    guard let token=self.hostTextBridgeSession?.token else{return}
                    NSPasteboard.general.clearContents();NSPasteboard.general.setString(token,forType:.string)
                    self.hostTextState.stringValue="联动码已复制，请在网页文本页粘贴并连接。"
                }catch{self.stopHostTextBridge();self.hostTextState.stringValue=error.localizedDescription}
            }else if enabled,response == .alertSecondButtonReturn{self.stopHostTextBridge();self.hostTextState.stringValue="网页联动已关闭，文本服务已停止。"}
        }
    }
    func stopHostTextBridge(){hostTextBridgeTimer?.invalidate();hostTextBridgeTimer=nil;hostTextBridge?.stop();hostTextBridge=nil;hostTextBridgeSession=nil;suspendHostTextForConfiguration()}
    func expireHostTextBridge(){
        if hostTextBridgeSession?.expired()==true{hostTextBridgeSession?.reset();if hostTextBridgeOwnsText{suspendHostTextForConfiguration();hostTextState.stringValue="网页联动已超时，文本服务已停止。"}}
    }
    func hostTextBridgeStatus()->[String:Any]{["format":"CherryMacHostTextBridge","version":1,"state":hostTextBridgeOwnsText ? hostTextService.stage.rawValue:"stopped","busy":busy]}
    func handleHostTextBridge(_ request:HostTextBridgeRequest,completion:@escaping HostTextBridgeHTTP.Completion){
        let origin=request.headers["origin"]
        do{
            expireHostTextBridge()
            guard let session=hostTextBridgeSession,hostTextBridge != nil else{throw HardwareError(message:"网页联动未开启。")}
            try session.authorize(request)
            guard let body=try JSONSerialization.jsonObject(with:request.body) as? [String:Any] else{throw HardwareError(message:"联动请求需要 JSON 对象。")}
            switch request.path {
            case "/v1/pair","/v1/status":completion(HostTextBridgeRequest.response(origin:origin,object:hostTextBridgeStatus()))
            case "/v1/activate":
                guard !busy,macroRecordingSheet==nil,window?.attachedSheet==nil,window?.isVisible==true,let root=body["officialJSON"] as? [String:Any] else{throw HardwareError(message:"请先完成客户端当前操作，并保持配置窗口开启。")}
                let data=try JSONSerialization.data(withJSONObject:root,options:[.sortedKeys]);try loadHostTextProfile(data,name:"网页文本配置")
                try hostTextService.start(officialJSON:data);hostTextBridgeOwnsText=true
                completion(HostTextBridgeRequest.response(origin:origin,object:hostTextBridgeStatus()))
            case "/v1/suspend","/v1/unpair":
                guard !busy,macroRecordingSheet==nil else{throw HardwareError(message:"客户端正在处理配置，请稍后重试。")}
                suspendHostTextForConfiguration();busy=true;controls.forEach{$0.isEnabled=false}
                queue.async{[weak self] in DispatchQueue.main.async{[weak self] in
                    guard let self else{completion(HostTextBridgeRequest.response(status:503,origin:origin));return}
                    self.busy=false;self.controls.forEach{$0.isEnabled=true};self.update()
                    if request.path=="/v1/unpair"{session.reset()}
                    completion(HostTextBridgeRequest.response(origin:origin,object:self.hostTextBridgeStatus()))
                }}
            default:throw HardwareError(message:"联动请求不支持。")
            }
        }catch{completion(HostTextBridgeRequest.response(status:409,origin:origin,object:["error":error.localizedDescription]))}
    }
    @objc func exportHostTextRecords(){
        guard !busy,macroRecordingSheet==nil,window?.attachedSheet==nil,let window else{return}
        let panel=NSSavePanel();panel.nameFieldStringValue="CherryMac-文本恢复记录.json"
        panel.beginSheetModal(for:window){[weak self] response in
            guard response == .OK,let self,let url=panel.url else{return}
            self.busy=true;self.controls.forEach{$0.isEnabled=false};let store=self.hostTextStore
            self.queue.async{[weak self] in
                let result=Result<Void,Error>{let data=try store.exportRecords();try data.write(to:url,options:.atomic)}
                DispatchQueue.main.async{guard let self else{return};self.busy=false;self.controls.forEach{$0.isEnabled=true};self.update()
                    do{try result.get();self.hostTextState.stringValue="文本恢复记录已导出，可在 Mac 或网页导入。"}catch{self.hostTextState.stringValue=error.localizedDescription}
                }
            }
        }
    }
    @objc func importHostTextRecords(){
        guard !busy,macroRecordingSheet==nil,window?.attachedSheet==nil,let window else{return}
        let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        panel.beginSheetModal(for:window){[weak self] response in
            guard response == .OK,let self,let url=panel.url else{return}
            self.suspendHostTextForConfiguration();self.busy=true;self.controls.forEach{$0.isEnabled=false};let store=self.hostTextStore
            self.queue.async{[weak self] in
                let result=Result<Int,Error>{
                    let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
                    guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 8_000_000 else{throw HardwareError(message:"文本恢复记录超过 8 MB。")}
                    return try store.importRecords(Data(contentsOf:url))
                }
                DispatchQueue.main.async{guard let self else{return};self.busy=false;self.controls.forEach{$0.isEnabled=true};self.update()
                    do{let count=try result.get();self.hostTextState.stringValue="已导入 \(count) 条文本恢复记录，键盘未改写，服务保持关闭。恢复前请读取键盘并核对确认。"}catch{self.hostTextState.stringValue=error.localizedDescription}
                }
            }
        }
    }
    @objc func editHostText(){
        guard !busy,hostTextEditor==nil,let data=hostTextJSON,let baseline,let window else{hostTextState.stringValue="请先读取键盘并选择官方配置。";return}
        suspendHostTextForConfiguration();busy=true;controls.forEach{$0.isEnabled=false}
        queue.async{[weak self] in
            let result=Result<[UInt8],Error>{
                let usb=try CherryUSB();let before=try usb.read(8,count:378),factory=try usb.read(7,count:378),after=try usb.read(8,count:378)
                guard before==baseline.keymap,after==before else{throw HardwareError(message:"文本编辑准备期间键位变化，请重新读取。")};return factory
            }
            DispatchQueue.main.async{guard let self else{return};self.busy=false;self.controls.forEach{$0.isEnabled=true};self.update()
                do{let factory=try result.get(),slot=keyboardLayout().first(where:{$0.id==self.selected}).flatMap{CherryMatrix.slot($0)}
                    let editor=try HostTextEditor(source:data,factory:factory,selected:slot){[weak self] edited in
                        guard let self else{return};self.hostTextEditor=nil
                        guard let edited else{return}
                        do{try self.loadHostTextProfile(edited,name:"编辑后的文本配置");self.hostTextState.stringValue="文本配置已修改，尚未写入。请核对安装或导出保存。"}catch{self.hostTextState.stringValue=error.localizedDescription}
                    }
                    self.hostTextEditor=editor;window.beginSheet(editor.window!)
                }catch{self.hostTextState.stringValue=error.localizedDescription}
            }
        }
    }
    @objc func installHostText(){
        guard !busy,macroRecordingSheet==nil,let data=hostTextJSON,let baseline,let window else{hostTextState.stringValue="请先读取键盘并选择文本配置。";return}
        suspendHostTextForConfiguration();busy=true;controls.forEach{$0.isEnabled=false};hostTextState.stringValue="正在读取默认表并核对文本安装计划…"
        queue.async{[weak self] in
            let result=Result<WindowsProfile.HostTextInstallation,Error>{
                let usb=try CherryUSB(),log=try HardwareOperationLog(kind:"text-install-preparation");usb.trace=log.trace
                do{let plan=try usb.readHostTextInstallation(officialJSON:data,baseline:baseline);log.record("phase","complete");return plan}
                catch{log.record("phase","failed");log.record("error",error.localizedDescription);throw error}
            }
            DispatchQueue.main.async{guard let self else{return};self.busy=false;self.controls.forEach{$0.isEnabled=true};self.update()
                switch result{
                case .failure(let error):self.hostTextState.stringValue=error.localizedDescription
                case .success(let plan):
                    let labels=Dictionary(uniqueKeysWithValues:keyboardLayout().compactMap{key in CherryMatrix.slot(key).map{($0,key.label.replacingOccurrences(of:"\n",with:" / "))}})
                    let review=(plan.bindings.map{binding in "\(labels[binding.physicalSlot] ?? "按键 \(binding.physicalSlot)") → 文本（\(binding.plan.originalText.count) 字符）"}+plan.removedSlots.map{"\(labels[$0] ?? "按键 \($0)") → 恢复默认"}).joined(separator:"\n")
                    let alert=NSAlert();alert.messageText="更新文本绑定？"
                    alert.informativeText=review+"\n\n其中 \(plan.changedSlots.count) 个键位需要写入。请松开全部按键，保持 USB 有线连接。文本输入需要 CherryMac 持续运行，灯效与宏区保留。"
                    alert.addButton(withTitle:"安装并保存");alert.addButton(withTitle:"取消")
                    alert.beginSheetModal(for:window){[weak self] response in
                        guard let self,response == .alertFirstButtonReturn,!self.busy,self.hostTextJSON==data else{return}
                        self.performHostTextInstallation(plan)
                    }
                }
            }
        }
    }
    func performHostTextInstallation(_ plan:WindowsProfile.HostTextInstallation){
        guard !busy else{return}
        suspendHostTextForConfiguration();busy=true;controls.forEach{$0.isEnabled=false}
        let previousDraft=profile,store=hostTextStore
        hostTextState.stringValue="正在备份并安装文本绑定，请勿按键或拔线…"
        queue.async{[weak self] in
            let result=Result<HardwareSnapshot,Error>{
                let log=try HardwareOperationLog(kind:"product-text-install"),usb=try CherryUSB();var staged:HostTextInstallationRecord?
                do{
                    let after=try usb.applyHostTextInstallation(plan,log:log,saveHostConfiguration:{data in
                        guard data==plan.officialJSON else{throw HardwareError(message:"文本配置在安装时发生变化。")}
                        staged=try store.prepare(plan);log.record("textRecordID",staged!.id);try log.requireHealthy()
                    })
                    guard let staged else{throw HardwareError(message:"文本安装没有保存主机定义。")}
                    do{try store.commit(staged)}catch{throw HardwareError(message:"键盘读回已通过，但主机文本配置提交失败。请保留安装记录并恢复：\(error.localizedDescription)")}
                    log.record("phase","complete");return after
                }catch{if let staged{do{try store.failed(staged)}catch{log.record("textRecordFailure",error.localizedDescription)}};log.record("phase","failed");log.record("error",error.localizedDescription);throw error}
            }
            DispatchQueue.main.async{self?.finishHostTextOperation(result,plan:plan,previousDraft:previousDraft,recovery:false)}
        }
    }
    @objc func restoreHostText(){
        guard !busy,macroRecordingSheet==nil,let window else{return}
        suspendHostTextForConfiguration();busy=true;controls.forEach{$0.isEnabled=false}
        let store=hostTextStore
        queue.async{[weak self] in
            let result=Result<HostTextInstallationRecord,Error>{guard let record=try store.latest(),record.phase != .restored else{throw HardwareError(message:"没有需要恢复的文本安装记录。")};return record}
            DispatchQueue.main.async{guard let self else{return};self.busy=false;self.controls.forEach{$0.isEnabled=true};self.update()
                do{let record=try result.get(),plan=try record.installation()
                    let alert=NSAlert();alert.messageText="恢复最近文本安装？";alert.informativeText="恢复安装前的键位与主机文本定义。程序会核对保存记录和完整配置；有其他配置变化时停止覆盖。请松开全部按键，保持 USB 有线连接。"
                    alert.addButton(withTitle:"恢复");alert.addButton(withTitle:"取消")
                    alert.beginSheetModal(for:window){[weak self] response in
                        guard let self,response == .alertFirstButtonReturn,!self.busy else{return}
                        self.suspendHostTextForConfiguration();self.busy=true;self.controls.forEach{$0.isEnabled=false}
                        let previousDraft=self.profile
                        self.hostTextState.stringValue="正在核对并恢复文本安装…"
                        self.queue.async{[weak self] in
                            let result=Result<HardwareSnapshot,Error>{
                                let log=try HardwareOperationLog(kind:"product-text-recovery")
                                do{try store.validateRestoration(record)
                                    let snapshot=try CherryUSB().recoverHostTextInstallation(plan,log:log)
                                    do{try store.restored(record)}catch{throw HardwareError(message:"键位已恢复，但主机文本定义恢复失败：\(error.localizedDescription)")}
                                    log.record("phase","complete");return snapshot
                                }catch{log.record("phase","failed");log.record("error",error.localizedDescription);throw error}
                            }
                            DispatchQueue.main.async{guard let self else{return};self.finishHostTextOperation(result,plan:plan,previousDraft:previousDraft,recovery:true)
                                if case .success = result{self.hostTextJSON=record.previousConfiguration;self.hostTextFile.stringValue=record.previousConfiguration==nil ? "已恢复：没有先前文本配置":"已恢复先前文本配置"}
                            }
                        }
                    }
                }catch{self.hostTextState.stringValue=error.localizedDescription}
            }
        }
    }
    func finishHostTextOperation(_ result:Result<HardwareSnapshot,Error>,plan:WindowsProfile.HostTextInstallation,previousDraft:HardwareProfile?,recovery:Bool){
        busy=false;controls.forEach{$0.isEnabled=true}
        switch result{
        case .success(let snapshot):
            baseline=snapshot;baselineWasRead=true
            var remaining=previousDraft ?? (try? HardwareProfile.fromHardware(snapshot)) ?? HardwareProfile(snapshot:snapshot)
            for slot in plan.bindings.map({$0.physicalSlot})+plan.removedSlots{remaining.snapshot.keymap.replaceSubrange(slot*3..<slot*3+3,with:snapshot.keymap[slot*3..<slot*3+3]);remaining.macroBindings?.removeValue(forKey:slot);remaining.macroModes?.removeValue(forKey:slot)}
            profile=remaining;loadLighting();refreshMacroPicker();loadSelectedAssignment()
            hostTextState.stringValue=recovery ? "键位与先前文本定义已恢复，服务保持关闭。":"文本绑定已安装并完整读回，配置已保存。切换到目标应用前请启用文本服务。"
            message.stringValue=hostTextState.stringValue
        case .failure(let error):baseline=nil;hostTextState.stringValue=error.localizedDescription;message.stringValue="文本操作未完成。请重新读取后核对或恢复，已有记录保留。"
        };update()
    }
    @objc func stopHostTextService(){suspendHostTextForConfiguration()}
    @objc func openHostTextLog(){
        guard let url=hostTextService.diagnosticURL else{hostTextState.stringValue="启用服务后会自动生成日志，日志不记录文本内容。";return}
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    #endif
    @objc func openMacSettings(){(NSApp.delegate as? Adapter)?.showSettings()}
    @objc func chooseTab(_ sender:NSButton){
        guard let tabs=tabView,(0..<tabs.tabViewItems.count).contains(sender.tag) else{return}
        tabs.selectTabViewItem(at:sender.tag)
        for tab in tabButtons{tab.state=tab.tag==sender.tag ? .on:.off;tab.needsDisplay=true}
        var titles=["按键功能","灯效","宏","配置与备份","设备与诊断"]
        var descriptions=["点选一个按键，设置你习惯的功能。","选择内置模式，或为每个按键配色。","把连续的按键操作保存为一个动作。","保存配置，管理备份，迁移你的设置。","查看连接状态与操作日志。"]
        #if CHERRY_MACRO_PRODUCT
        titles.append("文本快捷输入");descriptions.append("管理需要 Mac 端服务执行的文本动作。")
        #endif
        titles.append("设备设置");descriptions.append("管理官方配置草稿与 Mac 端适配。")
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
        if let name=profile.macroBindings?[slot],macroPicker.itemTitles.contains(name){macroPicker.selectItem(withTitle:name);chooseMacro()}
        let chosenMacro=profile.macros.first(where:{$0.name==macroPicker.titleOfSelectedItem})
        let playback=profile.macroBindings?[slot] != nil ? (profile.macroModes?[slot] ?? .once):(chosenMacro?.preferredPlayback ?? .once)
        macroPlayback.selectItem(at:playback.mode == .count ? 0:playback.mode == .held ? 1:2);macroRepeat.stringValue=String(playback.count);playbackChanged()
        let bytes=Array(profile.snapshot.keymap[slot*3..<slot*3+3])
        let presets:[[UInt8]]=[[0x20,13,6],[0x20,10,33],[0x20,8,21],[0x30,182,0],[0x30,205,0],[0x30,181,0],[0x20,0,0]]
        if let preset=presets.firstIndex(of:bytes){actionPicker.selectItem(at:preset+2)}else if bytes==MacApplicationShortcut.finder.record{actionPicker.selectItem(at:10)}else if bytes==MacApplicationShortcut.mail.record{actionPicker.selectItem(at:11)}else if bytes==MacApplicationShortcut.music.record{actionPicker.selectItem(at:12)}else{
            actionPicker.selectItem(at:0)
            if bytes[0]==0x20 {
                actionPicker.selectItem(at:1)
                if let item=shortcutKeys.firstIndex(where:{$0.1==bytes[2]}){keyPicker.selectItem(at:item)}
                for (index,button) in modifiers.enumerated(){button.state=bytes[1] & [UInt8(0x88),0x11,0x44,0x22][index] == 0 ? .off:.on}
            }else{keyPicker.selectItem(at:0);modifiers.forEach{$0.state = .off}
                if bytes[0]==0x30,let index=WindowsProfile.mediaCodes.firstIndex(of:UInt16(bytes[1]) | UInt16(bytes[2])<<8),WindowsProfile.visibleMediaIndices.contains(index){actionPicker.selectItem(at:9);mediaPicker.selectItem(at:mediaPicker.indexOfItem(withTag:index))}
            }
        }
        actionChanged()
    }
    func update(){
        playbackChanged()
        macroCancellationButton?.isHidden=currentMacroOperation==nil
        macroCancellationButton?.isEnabled=busy && currentMacroOperation?.isCancelled==false
        writeButtons.forEach{$0.isEnabled=false}
        if let lightingButton=writeButtons.first(where:{$0.tag==1}){
            #if CHERRY_LIGHTING_TEST
            lightingButton.title="准备灯效写入…"
            lightingButton.toolTip="进入独立流程，先重新读取并备份；不会直接发送。"
            #else
            lightingButton.title="核对灯效计划…"
            lightingButton.toolTip="仅核对并导出计划；普通版尚未开放灯效发送。"
            #endif
            lightingButton.isEnabled = !busy && baselineWasRead && baseline != nil && profile != nil
        }
        if !busy,let baseline,let profile,profile.snapshot.deviceInfo==baseline.deviceInfo,let plan=try? KeymapWriteAuthorization(baseline:baseline,keymap:profile.snapshot.keymap){writeButtons.first?.isEnabled = !plan.changedSlots.isEmpty;writeButtons.first?.toolTip="仅写键位表；灯效与宏区保留。"}
        #if CHERRY_MACRO_PRODUCT
        if !busy,let target=try? macroWriteTarget(),let baseline{
            writeButtons.first(where:{$0.tag==2})?.isEnabled=target.keymap != baseline.keymap || target.macroData != baseline.macroData
            writeButtons.first(where:{$0.tag==2})?.toolTip="只写宏区与宏绑定键；普通键和灯效草稿保留。"
        }
        #endif
        // Official RGB is a raw draft, whereas the device stores scaled RGB.
        // Compare the projected write target so a completed write is not
        // displayed as a pending change solely because brightness was applied.
        var lightingComparisonColors=profile?.snapshot.colors
        if lightingTab,let draft=profile,let baseline,draft.lightingColorEncoding == .officialRGB,
           let review=try? WindowsProfile.reviewLightingDraft(draft,baseline:baseline){
            lightingComparisonColors=review.target.colors
        }
        for b in keyButtons{b.chosen=lightingTab ? lightSelection.contains(b.spec.id):b.spec.id==selected
            b.lightingColor=nil
            if lightingTab,let keySlot=CherryMatrix.slot(b.spec),let p=profile,let slot=p.colorSlot(keySlot),let colors=p.snapshot.colors{b.lightingColor=NSColor(srgbRed:CGFloat(colors[slot*3])/255,green:CGFloat(colors[slot*3+1])/255,blue:CGFloat(colors[slot*3+2])/255,alpha:1)}
            if let slot=CherryMatrix.slot(b.spec),let p=profile,let original=baseline{
                if lightingTab{if let colorSlot=p.colorSlot(slot),let colors=lightingComparisonColors,let previous=original.colors{b.mapped=colors[colorSlot*3..<colorSlot*3+3] != previous[colorSlot*3..<colorSlot*3+3]}else{b.mapped=false}}else{b.mapped=p.snapshot.keymap[slot*3..<slot*3+3] != original.keymap[slot*3..<slot*3+3]}
            }else{b.mapped=false}}
        lightCount.stringValue="已选 \(lightSelection.count) 键"
        guard let key=keyboardLayout().first(where:{$0.id==selected})else{return}
        selectedLabel.stringValue=key.label
        if let slot=CherryMatrix.slot(key),let p=profile{
            recordLabel.stringValue="当前配置："+(p.macroBindings?[slot].map{"宏 · \($0) · \((p.macroModes?[slot] ?? .once).label)"} ?? CherryMatrix.describe(Array(p.snapshot.keymap[slot*3..<slot*3+3])))
        }else{recordLabel.stringValue="读取键盘后可查看此键配置"}
    }
    func loadLighting(){
        guard let profile else{return}
        let parameters=profile.snapshot.parameters
        modes[0].1=parameters[1];modePicker.item(at:0)?.title="保留当前模式（\(parameters[1])）";modePicker.selectItem(at:0)
        globalLightColor.color=NSColor(srgbRed:CGFloat(parameters[6])/255,green:CGFloat(parameters[7])/255,blue:CGFloat(parameters[8])/255,alpha:1)
        brightness.doubleValue=Double(parameters[2]);speed.doubleValue=Double(4-Int(parameters[3]));lightDirection.selectItem(at:0);lightRainbow.selectItem(at:0);loadLightColor()
    }
    func recalledMacroProfile(_ snapshot:HardwareSnapshot)->HardwareProfile?{
        let files=(try? FileManager.default.contentsOfDirectory(at:backupDirectory,includingPropertiesForKeys:[.contentModificationDateKey])) ?? []
        let candidates=files.filter{$0.lastPathComponent.hasPrefix("MacroMetadata-") && $0.pathExtension=="json"}.sorted{((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)}
        for url in candidates.prefix(128){
            guard let data=try? Data(contentsOf:url),var saved=try? HardwareProfile.decode(data),saved.snapshot.deviceInfo==snapshot.deviceInfo else{continue}
            saved.snapshot=snapshot;saved.lightingColorEncoding = .hardwareRGB
            guard let resolved=try? saved.resolvedMacros(),resolved.keymap==snapshot.keymap,resolved.macroData==snapshot.macroData else{continue}
            return saved
        };return nil
    }
    func rememberMacroProfile(_ draft:HardwareProfile,snapshot:HardwareSnapshot)throws{
        var saved=draft;saved.snapshot=snapshot;saved.lightingColorEncoding = .hardwareRGB;let resolved=try saved.resolvedMacros()
        guard resolved.deviceInfo==snapshot.deviceInfo,resolved.keymap==snapshot.keymap,resolved.macroData==snapshot.macroData else{throw HardwareError(message:"宏名称与设备数据不一致，未保存名称。")}
        try FileManager.default.createDirectory(at:backupDirectory,withIntermediateDirectories:true)
        let url=backupDirectory.appendingPathComponent("MacroMetadata-\(UUID().uuidString).json"),data=try saved.encoded()
        try data.write(to:url,options:.atomic)
        guard try Data(contentsOf:url)==data else{throw HardwareError(message:"宏名称保存校验失败。")}
        UserDefaults.standard.set(url.path,forKey:"hardware.macroMetadata")
    }
    var backupDirectory:URL{FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CherryMac/HardwareBackups")}
    @objc func readKeyboard(){
        guard !busy else{return}
        if let draft=profile{
            let original=baseline ?? HardwareSnapshot.demo()
            let resolved=(try? draft.resolvedMacros()) ?? draft.snapshot
            let contentChanged=resolved.deviceInfo != original.deviceInfo || resolved.keymap != original.keymap || resolved.parameters != original.parameters || resolved.colors != original.colors || resolved.macroData != original.macroData
            let replacesDraft=draft.windowsTemplateJSON != nil || draft.hostTextJSON != nil || contentChanged
            if replacesDraft{
                let alert=NSAlert();alert.messageText="重新读取并替换编辑区？"
                alert.informativeText="当前编辑区含草稿或导入的配置资料。重新读取会用键盘配置替换它们；请先在配置与备份导出保存。读取本身不会写入键盘。"
                alert.addButton(withTitle:"取消，保留编辑区");alert.addButton(withTitle:"已保存，重新读取")
                guard alert.runModal() == .alertSecondButtonReturn else{return}
            }
        }
        readKeyboardThen()
    }
    func readKeyboardThen(_ completion:((HardwareSnapshot)->Void)? = nil){
        guard !busy else{return};suspendHostTextForConfiguration();busy=true;controls.forEach{$0.isEnabled=false};message.stringValue="正在读取 USB 配置…"
        queue.async{[weak self] in
            let result:Result<(snapshot:HardwareSnapshot,mapping:LightingMappingContext?,mappingError:String?),Error>=Result{
                let log=try HardwareOperationLog(kind:"read")
                do{
                    try log.requireHealthy();let usb=try CherryUSB();usb.trace=log.trace
                    let snapshot=try usb.completeSnapshot();log.record("phase","lighting-mapping-read")
                    var mapping:LightingMappingContext?,mappingError:String?
                    do{mapping=try usb.readLightingMapping(snapshot)}catch{mappingError=error.localizedDescription;log.record("lighting-mapping-error",error.localizedDescription)}
                    log.record("phase","complete");try log.requireHealthy();return (snapshot,mapping,mappingError)
                }catch{log.record("phase","failed");log.record("error",error.localizedDescription);throw error}
            }
            DispatchQueue.main.async{guard let self else{return};self.busy=false;self.controls.forEach{$0.isEnabled=true};self.writeButtons.forEach{$0.isEnabled=false}
                switch result{case .success(let read):
                    let snapshot=read.snapshot
                    self.baseline=snapshot;self.baselineWasRead=true;self.profile=self.recalledMacroProfile(snapshot) ?? (try? HardwareProfile.fromHardware(snapshot)) ?? HardwareProfile(snapshot:snapshot)
                    self.profile?.lightingMapping=read.mapping;self.baselineLightingMapping=read.mapping
                    self.connection.stringValue="USB 已连接 · 126 个固件键位 · 已读取键位、灯效与宏区"
                    self.loadLighting();self.refreshMacroPicker()
                    do{try FileManager.default.createDirectory(at:self.backupDirectory,withIntermediateDirectories:true)
                        let url=self.backupDirectory.appendingPathComponent("USB-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json")
                        try self.profile!.encoded().write(to:url,options:.atomic);self.message.stringValue=self.profile!.macroBindings==nil ? "读取并备份完成。原宏格式暂不支持编辑，原始宏区已保留。":"读取完成，已自动备份。可以点选键位、编辑灯效与宏。"}
                    catch{self.message.stringValue="读取完成，备份失败：\(error.localizedDescription)"}
                    if let error=read.mappingError{self.message.stringValue += "\n灯光映射未取得：\(error) 按键和宏读取结果已保留。"}
                    self.loadSelectedAssignment();self.update()
                    completion?(snapshot)
                case .failure(let error):self.baseline=nil;self.connection.stringValue="USB 读取失败";self.message.stringValue=error.localizedDescription;self.update()}
            }
        }
    }
    @objc func writeKeys(){
        suspendHostTextForConfiguration()
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
        suspendHostTextForConfiguration()
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
    #if CHERRY_MACRO_PRODUCT
    func macroWriteTarget()throws->HardwareSnapshot{
        guard let draft=profile,let baseline else{throw HardwareError(message:"请先读取键盘。")}
        var target=try draft.resolvedMacros()
        guard target.deviceInfo==baseline.deviceInfo else{throw HardwareError(message:"配置固件信息与当前键盘不一致，请重新读取。")}
        target.parameters=baseline.parameters;target.colors=baseline.colors
        for slot in 0..<126 where ![UInt8(0x70),0x71].contains(baseline.keymap[slot*3]) && ![UInt8(0x70),0x71].contains(target.keymap[slot*3]){target.keymap.replaceSubrange(slot*3..<slot*3+3,with:baseline.keymap[slot*3..<slot*3+3])}
        return try MacroWriteAuthorization(baseline:baseline,target:target,allowUnbounded:true).expected
    }
    @objc func cancelMacroOperation(){
        guard busy,let log=currentMacroOperation else{return};log.requestCancellation();message.stringValue="已请求停止发送，等待当前 USB 回复；原配置与恢复记录保留。";update()
    }
    @objc func restoreLastMacros(){
        suspendHostTextForConfiguration()
        guard !busy,let owner=window else{return}
        let authorization:MacroWriteAuthorization
        do{
            guard let path=UserDefaults.standard.string(forKey:"hardware.lastMacroOperation") else{throw HardwareError(message:"没有可恢复的宏写入记录。")}
            let data=try Data(contentsOf:URL(fileURLWithPath:path))
            guard data.count<=20_000_000,let saved=try JSONSerialization.jsonObject(with:data) as? [String:Any],saved["format"] as? String=="CherryMacHardwareOperation",saved["version"] as? Int==1,saved["kind"] as? String=="product-macro-write",
                let beforeText=saved["before"] as? String,let targetText=saved["target"] as? String,let beforeData=Data(base64Encoded:beforeText),let targetData=Data(base64Encoded:targetText) else{throw HardwareError(message:"宏写入记录不完整，未恢复。")}
            authorization=try MacroWriteAuthorization(baseline:HardwareProfile.decode(beforeData).snapshot,target:HardwareProfile.decode(targetData).snapshot,allowUnbounded:true)
        }catch{message.stringValue=error.localizedDescription;return}
        let panel=NSAlert();panel.messageText="恢复最近宏写入前配置";panel.informativeText="请保持 USB 有线连接并松开全部按键。只恢复保存记录里的宏库和宏绑定；读取到其他配置变化会停止恢复。";panel.addButton(withTitle:"全部已松开，恢复");panel.addButton(withTitle:"取消")
        panel.beginSheetModal(for:owner){[weak self] response in
            guard let self,response == .alertFirstButtonReturn,!self.busy else{return}
            let operationLog:HardwareOperationLog
            do{operationLog=try HardwareOperationLog(kind:"product-macro-recovery")}catch{self.message.stringValue=error.localizedDescription;return}
            let previousDraft=self.profile
            self.currentMacroOperation=operationLog;self.busy=true;self.controls.forEach{$0.isEnabled=false};self.update();self.message.stringValue="正在读取并恢复宏配置…"
            self.queue.async{[weak self] in
                let result=Result<HardwareSnapshot,Error>{
                    let log=operationLog
                    return try CherryUSB().recoverMacro(authorization,log:log,confirmStopped:{request in
                        try MacroPhysicalStopController.confirm(request,owner:owner,directory:log.url.deletingLastPathComponent().appendingPathComponent("\(log.url.deletingPathExtension().lastPathComponent)-stop-\(UUID().uuidString)"))
                    })
                }
                DispatchQueue.main.async{guard let self else{return};self.currentMacroOperation=nil;self.busy=false;self.controls.forEach{$0.isEnabled=true}
                    switch result{
                    case .success(let snapshot):
                        self.baseline=snapshot;self.baselineWasRead=true
                        let restored=self.recalledMacroProfile(snapshot) ?? (try? HardwareProfile.fromHardware(snapshot)) ?? HardwareProfile(snapshot:snapshot)
                        do{
                            self.profile=try HardwareProfile.mergeMacroRecovery(restored:restored,previous:previousDraft,before:authorization.before,target:authorization.expected)
                            self.message.stringValue="宏原配置已恢复，完整读回一致；其他草稿保留。"
                        }catch{
                            self.profile=previousDraft ?? restored
                            self.message.stringValue="键盘宏已恢复且读回一致，但草稿合并失败：\(error.localizedDescription)。原编辑区保留，尚未写入。"
                        }
                        self.loadLighting();self.refreshMacroPicker();self.loadSelectedAssignment();
                    case .failure(let error):self.baseline=nil;self.message.stringValue=error.localizedDescription+" 保存的恢复记录仍保留。"
                    };self.update()
                }
            }
        }
    }
    @objc func writeMacros(){
        suspendHostTextForConfiguration()
        guard !busy,let draft=profile,let baseline,let owner=window else{message.stringValue="请先读取键盘。";return}
        let target:HardwareSnapshot
        do{target=try macroWriteTarget()}catch{message.stringValue=error.localizedDescription;return}
        guard target.keymap != baseline.keymap || target.macroData != baseline.macroData else{message.stringValue="没有待写入的宏或键位改动。";return}
        let labels=Dictionary(uniqueKeysWithValues:keyboardLayout().compactMap{key in CherryMatrix.slot(key).map{($0,key.label.replacingOccurrences(of:"\n",with:" / "))}})
        let review:String
        do{review=try draft.macroWriteReview(before:baseline,target:target,labels:labels)}catch{message.stringValue=error.localizedDescription;return}
        let panel=NSAlert();panel.messageText="写入宏与绑定键";panel.informativeText=review+"\n\n仅更新宏库和宏绑定键，普通键与灯效草稿保留。请先停止正在运行的宏并松开全部键；将保存完整备份，写入后完整读回。";panel.addButton(withTitle:"全部已松开，开始写入");panel.addButton(withTitle:"返回编辑")
        panel.beginSheetModal(for:owner){[weak self] response in
            guard let self,response == .alertFirstButtonReturn,!self.busy else{return}
            // Freeze the review scope; a changed draft/baseline requires a new review.
            do{guard try self.macroWriteTarget()==target,self.baseline==baseline else{throw HardwareError(message:"确认期间编辑区或键盘基线变化，请重新核对。")}}catch{self.message.stringValue=error.localizedDescription;return}
            let operationLog:HardwareOperationLog
            do{operationLog=try HardwareOperationLog(kind:"product-macro-write")}catch{self.message.stringValue=error.localizedDescription;return}
            self.currentMacroOperation=operationLog;self.busy=true;self.controls.forEach{$0.isEnabled=false};self.update();self.message.stringValue="正在备份并写入宏与键位；请勿按键或拔线。"
            self.queue.async{[weak self] in
                let result=Result<HardwareSnapshot,Error>{
                    let log=operationLog
                    defer{if log.string("before") != nil && log.string("target") != nil{UserDefaults.standard.set(log.url.path,forKey:"hardware.lastMacroOperation")}}
                    return try CherryUSB().applyMacro(target,baseline:baseline,log:log,confirmStopped:{request in
                        try MacroPhysicalStopController.confirm(request,owner:owner,directory:log.url.deletingLastPathComponent().appendingPathComponent("\(log.url.deletingPathExtension().lastPathComponent)-stop-\(UUID().uuidString)"))
                    })
                }
                DispatchQueue.main.async{guard let self else{return};self.currentMacroOperation=nil;self.busy=false;self.controls.forEach{$0.isEnabled=true};self.actionChanged()
                    switch result{
                    case .success(let snapshot):self.baseline=snapshot;var remaining=draft;for slot in 0..<126 where baseline.keymap[slot*3..<slot*3+3] != snapshot.keymap[slot*3..<slot*3+3]{remaining.snapshot.keymap.replaceSubrange(slot*3..<slot*3+3,with:snapshot.keymap[slot*3..<slot*3+3])};remaining.snapshot.macroData=snapshot.macroData;self.profile=remaining;self.update();do{try self.rememberMacroProfile(remaining,snapshot:snapshot)}catch{self.message.stringValue="宏已写入并读回一致，但本地名称保存失败：\(error.localizedDescription)";return};self.message.stringValue="宏与按键写入完成，完整读回一致；备份与日志已保存。普通键与灯效草稿保留在编辑区。"
                    case .failure(let error):self.baseline=nil;self.update();self.message.stringValue=error.localizedDescription+" 请重新连接并读取后核对；备份和日志已保留。"
                    }
                }
            }
        }
    }
    #else
    @objc func writeMacros(){
        suspendHostTextForConfiguration()
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
    #endif
    @objc func writeLighting(){
        guard !busy,baselineWasRead,baseline != nil,profile != nil else{
            message.stringValue="请先读取键盘，再保存灯效到编辑区。";return
        }
        #if CHERRY_LIGHTING_TEST
        openLightingAcceptance()
        #else
        reviewLightingDraft()
        #endif
    }
    @objc func actionChanged(){keyPicker.isEnabled = !busy && actionPicker.indexOfSelectedItem==1;modifiers.forEach{$0.isEnabled = !busy && actionPicker.indexOfSelectedItem==1};mediaPicker.isEnabled = !busy && actionPicker.indexOfSelectedItem==9}
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
        case 9:
            guard let index=mediaPicker.selectedItem?.tag,WindowsProfile.visibleMediaIndices.contains(index)else{message.stringValue="请选择多媒体功能。";return}
            let code=WindowsProfile.mediaCodes[index];record=[0x30,UInt8(code&255),UInt8(code>>8)]
        case 10:record=MacApplicationShortcut.finder.record
        case 11:record=MacApplicationShortcut.mail.record
        case 12:record=MacApplicationShortcut.music.record
        default:var mask:UInt8=0;for (i,m) in modifiers.enumerated() where m.state == .on{mask |= [UInt8(8),1,4,2][i]};record=[0x20,mask,shortcutKeys[max(0,keyPicker.indexOfSelectedItem)].1]
        }
        p.macroBindings?.removeValue(forKey:slot);p.macroModes?.removeValue(forKey:slot)
        p.snapshot.keymap.replaceSubrange(slot*3..<slot*3+3,with:record);profile=p;message.stringValue="已编辑 \(key.label)：\(CherryMatrix.describe(record))。尚未写入键盘。";update()
    }
    @objc func moveMacroStep(_ sender:NSButton){
        guard !busy,(0...3).contains(sender.tag) else{return}
        var lines=macroText.string.components(separatedBy:"\n")
        let selection=macroText.selectedRange(),text=macroText.string as NSString
        let caret=min(selection.location,text.length)
        let index=(text.substring(to:caret).components(separatedBy:"\n").count-1)
        guard lines.indices.contains(index),!lines[index].trimmingCharacters(in:.whitespaces).isEmpty else{return}
        let lineRange=text.lineRange(for:NSRange(location:caret,length:0))
        guard selection.length==0 || NSMaxRange(selection)<=NSMaxRange(lineRange) else{message.stringValue="请选中一个步骤再移动。";return}
        let target=[0,max(0,index-1),min(lines.count-1,index+1),lines.count-1][sender.tag]
        guard target != index else{return}
        let line=lines.remove(at:index);lines.insert(line,at:target);macroText.string=lines.joined(separator:"\n")
        let offset=lines.prefix(target).reduce(0){$0+($1 as NSString).length+1}
        macroText.setSelectedRange(NSRange(location:offset,length:(line as NSString).length));macroText.scrollRangeToVisible(macroText.selectedRange());updateMacroSummary()
        message.stringValue="步骤顺序已调整；保存宏时检查按下与松开是否配对。"
    }
    func parsedMacroSteps()throws->[KeyboardMacro.Step]{
        let lines=macroText.string.split(separator:"\n",omittingEmptySubsequences:true)
        return try lines.map{line -> KeyboardMacro.Step in
                let parts=line.split(whereSeparator:{$0.isWhitespace});guard parts.count>=3,let delay=Int(parts.last!),["按下","松开","down","up"].contains(String(parts[parts.count-2]))else{throw HardwareError(message:"宏格式错误：\(line)")}
                let name=parts.dropLast(2).joined(separator:" ")
                let mouse=self.mouseMacroKeys.first(where:{$0.0==name})
                let usage:UInt8?
                if let mouse{usage=mouse.1}else if name.hasPrefix("HID:"){usage=UInt8(name.dropFirst(4))}else{usage=self.hidKeys.first(where:{$0.0.caseInsensitiveCompare(name) == .orderedSame})?.1}
                guard let usage else{throw HardwareError(message:"无法识别宏按键：\(name)")}
                return KeyboardMacro.Step(usage:usage,pressed:["按下","down"].contains(String(parts[parts.count-2])),delayMilliseconds:delay,kind:mouse != nil ? .mouse:nil)}
    }
    @objc func editMacroSteps(){
        guard !busy,macroStepEditor==nil,macroRecordingSheet==nil,let parent=window else{return}
        do{
            let steps=try parsedMacroSteps()
            let choices=hidKeys.filter{$0.1 != 0}.map{MacroStepEditor.KeyChoice(name:$0.0,usage:$0.1,kind:nil)}+mouseMacroKeys.map{MacroStepEditor.KeyChoice(name:$0.0,usage:$0.1,kind:.mouse)}
            let editor=MacroStepEditor(steps:steps,choices:choices){[weak self] result in
                guard let self else{return};self.macroStepEditor=nil
                guard let result else{self.message.stringValue="步骤编辑已取消，原步骤保留。";return}
                self.macroText.string=result.map{step in "\((step.kind == .mouse ? self.mouseMacroKeys:self.hidKeys).first(where:{$0.1==step.usage})?.0 ?? "HID:\(step.usage)") \(step.pressed ? "按下":"松开") \(step.delayMilliseconds)"}.joined(separator:"\n")
                self.updateMacroSummary();self.message.stringValue="已采用 \(result.count) 个步骤，请点击保存宏。"
            }
            macroStepEditor=editor;parent.beginSheet(editor.window!)
        }catch{message.stringValue=error.localizedDescription}
    }
    @objc func stageMacro(){
        do{guard var p=profile else{throw HardwareError(message:"请先读取或导入配置。")}
            let steps=try parsedMacroSteps()
            if p.macroBindings==nil{
                let previous=try p.snapshot.macroData.map{try CherryMacroCodec.decode($0)} ?? []
                guard previous.isEmpty,!(0..<126).contains(where:{[UInt8(0x70),0x71].contains(p.snapshot.keymap[$0*3])}) else{throw HardwareError(message:"原硬件宏尚未解码，请先重新读取键盘后编辑。")}
                p.macroBindings=[:]
            }
            let selectedIndex=macroPicker.indexOfSelectedItem-1
            let existing=p.macros.indices.contains(selectedIndex) ? p.macros[selectedIndex]:nil
            guard !p.macros.enumerated().contains(where:{$0.offset != selectedIndex && $0.element.name==macroName.stringValue}) else{throw HardwareError(message:"宏名称已存在。")}
            let preference=recordingPreference ?? existing?.recordingDelay
            guard let count=macroPlayback.indexOfSelectedItem==0 ? Int(macroRepeat.stringValue):1 else{throw HardwareError(message:"请输入宏执行次数。")}
            let modes:[MacroPlayback.Mode]=[.count,.held,.toggle]
            guard modes.indices.contains(macroPlayback.indexOfSelectedItem) else{throw HardwareError(message:"请选择宏执行方式。")}
            let preferred=MacroPlayback(mode:modes[macroPlayback.indexOfSelectedItem],count:count);try preferred.validate()
            let macro=KeyboardMacro(name:macroName.stringValue,steps:steps,recordingDelay:preference,preferredPlayback:preferred,windowsActionIndex:existing?.windowsActionIndex,hardwareReserved:existing?.hardwareReserved);try macro.validate()
            if let existing{
                p.macros[selectedIndex]=macro
                for (slot,name) in p.macroBindings ?? [:] where name==existing.name{p.macroBindings?[slot]=macro.name}
            }else{p.macros.append(macro)}
            try p.validate();if p.macroBindings != nil{p.snapshot=try p.resolvedMacros()}
            profile=p;recordingPreference=nil;refreshMacroPicker(selected:macro.name);update()
            if baselineWasRead,let baseline,p.snapshot.deviceInfo==baseline.deviceInfo{
                var candidate=p;candidate.snapshot=baseline
                if let resolved=try? candidate.resolvedMacros(),resolved.keymap==baseline.keymap,resolved.macroData==baseline.macroData{do{try rememberMacroProfile(p,snapshot:baseline)}catch{message.stringValue="编辑区已保存，但本地宏名称／默认方式保存失败：\(error.localizedDescription)";return}}
            }
            message.stringValue="宏与默认执行方式已保存到编辑区，共 \(steps.count) 步。已有绑定不变，点击分配后应用到所选键。"
        }catch{message.stringValue=error.localizedDescription}
    }
    func refreshMacroPicker(selected:String?=nil){macroPicker.removeAllItems();macroPicker.addItem(withTitle:"新建宏");macroPicker.addItems(withTitles:profile?.macros.map{$0.name} ?? []);if let selected{macroPicker.selectItem(withTitle:selected)}}
    @objc func chooseMacro(){
        recordingPreference=nil
        guard macroPicker.indexOfSelectedItem>0,let profile else{macroName.stringValue="新宏";macroText.string="";macroPlayback.selectItem(at:0);macroRepeat.stringValue="1";playbackChanged();return}
        let macro=profile.macros[macroPicker.indexOfSelectedItem-1];macroName.stringValue=macro.name
        let slot=keyboardLayout().first(where:{$0.id==selected}).flatMap{CherryMatrix.slot($0)}
        let playback=slot.flatMap{profile.macroBindings?[$0]==macro.name ? profile.macroModes?[$0]:nil} ?? macro.preferredPlayback ?? .once
        macroPlayback.selectItem(at:[MacroPlayback.Mode.count,.held,.toggle].firstIndex(of:playback.mode) ?? 0);macroRepeat.stringValue=String(playback.count)
        macroText.string=macro.steps.map{step in "\((step.kind == .mouse ? mouseMacroKeys:hidKeys).first(where:{$0.1==step.usage})?.0 ?? "HID:\(step.usage)") \(step.pressed ? "按下":"松开") \(step.delayMilliseconds)"}.joined(separator:"\n");updateMacroSummary()
    }
    @objc func recordMacro(){
        suspendHostTextForConfiguration()
        guard !busy,profile?.macroBindings != nil,let parent=window,macroRecordingSheet==nil else{return}
        let original:[KeyboardMacro.Step]
        do{original=try parsedMacroSteps()}catch{message.stringValue=error.localizedDescription;return}
        let text=macroText.string as NSString,caret=min(macroText.selectedRange().location,text.length)
        let preceding=text.substring(to:caret).components(separatedBy:"\n").dropLast().filter{!$0.trimmingCharacters(in:.whitespaces).isEmpty}.count
        let selectedStep=original.indices.contains(preceding) && !text.substring(with:text.lineRange(for:NSRange(location:caret,length:0))).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? preceding:nil
        let sheet=MacroRecordingSheet(name:macroName.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "录制宏":macroName.stringValue,originalSteps:original,selectedStep:selectedStep){[weak self] macro in
            guard let self else{return};self.macroRecordingSheet=nil
            guard let macro else{self.message.stringValue="录制已取消，原步骤保留。";return}
            self.recordingPreference=macro.recordingDelay;self.macroName.stringValue=macro.name
            self.macroText.string=macro.steps.map{step in "\((step.kind == .mouse ? self.mouseMacroKeys:self.hidKeys).first(where:{$0.1==step.usage})?.0 ?? "HID:\(step.usage)") \(step.pressed ? "按下":"松开") \(step.delayMilliseconds)"}.joined(separator:"\n")
            self.updateMacroSummary();self.message.stringValue="已采用 \(macro.steps.count) 个录制事件，请点击保存宏。"
        }
        macroRecordingSheet=sheet;parent.beginSheet(sheet.window!)
    }
    @objc func appendMacroKey(){
        guard let delay=Int(macroDelay.stringValue),(0...60000).contains(delay),let key=macroKey.titleOfSelectedItem else{message.stringValue="宏间隔须为 0…60000 毫秒。";return}
        macroText.string += (macroText.string.isEmpty || macroText.string.hasSuffix("\n") ? "":"\n") + "\(key) 按下 \(delay)\n\(key) 松开 0"
        updateMacroSummary()
    }
    func textDidChange(_ notification:Notification){updateMacroSummary()}
    func updateMacroSummary(){
        guard let profile,profile.macroBindings != nil else{macroSummary.stringValue="读取完整配置后显示宏容量。";return}
        do{
            let saved=try CherryMacroCodec.encode(profile.macros),used=profile.macros.isEmpty ? 0:Int(saved[2]) | Int(saved[3])<<8
            let library="宏库 \(profile.macros.count)/32 · 已占用 \(used)/3071 字节"
            guard !macroText.string.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{macroSummary.stringValue=library+"\n添加或录制步骤后显示本次保存容量。";return}
            do{
                let steps=try parsedMacroSteps(),macro=KeyboardMacro(name:macroName.stringValue,steps:steps)
                var draft=profile.macros;let index=macroPicker.indexOfSelectedItem-1
                if draft.indices.contains(index){draft[index]=macro}else{draft.append(macro)}
                guard Set(draft.map{$0.name}).count==draft.count else{throw HardwareError(message:"宏名称已存在。")}
                let bank=try CherryMacroCodec.encode(draft),next=Int(bank[2]) | Int(bank[3])<<8
                let cycle=steps.reduce(0){$0+$1.delayMilliseconds}
                guard let count=macroPlayback.indexOfSelectedItem==0 ? Int(macroRepeat.stringValue):1 else{throw HardwareError(message:"请输入宏执行次数。")}
                let mode:[MacroPlayback.Mode]=[.count,.held,.toggle]
                let playback=MacroPlayback(mode:mode[max(0,macroPlayback.indexOfSelectedItem)],count:count);try playback.validate()
                let duration=playback.mode == .count ? "\(cycle*count) ms":"每轮 \(cycle) ms · 持续执行"
                macroSummary.stringValue=library+"\n本次保存 \(next)/3071 字节 · \(steps.count) 步\n设定等待总量："+duration
            }catch{macroSummary.stringValue=library+"\n本次保存："+error.localizedDescription}
        }catch{macroSummary.stringValue="宏容量暂不可计算："+error.localizedDescription}
    }
    @objc func playbackChanged(){macroRepeat.isEnabled = !busy && macroPlayback.indexOfSelectedItem==0;updateMacroSummary()}
    @objc func assignMacro(){
        do{guard var p=profile,macroPicker.indexOfSelectedItem>0,let key=keyboardLayout().first(where:{$0.id==selected}),let slot=CherryMatrix.slot(key)else{throw HardwareError(message:"请先保存并选择一个宏，再点选键盘按键。")}
            let mode:[MacroPlayback.Mode]=[.count,.held,.toggle]
            guard let count=macroPlayback.indexOfSelectedItem==0 ? Int(macroRepeat.stringValue):1 else{throw HardwareError(message:"请输入宏执行次数。")}
            let playback=MacroPlayback(mode:mode[max(0,macroPlayback.indexOfSelectedItem)],count:count)
            let name=p.macros[macroPicker.indexOfSelectedItem-1].name;try p.assignMacro(named:name,to:slot,playback:playback);profile=p;loadSelectedAssignment();update();message.stringValue="已把「\(name)」分配到 \(key.label)，尚未写入键盘。"
        }catch{message.stringValue=error.localizedDescription}
    }
    @objc func copyMacro(){guard var p=profile,macroPicker.indexOfSelectedItem>0 else{return};do{let name=p.macros[macroPicker.indexOfSelectedItem-1].name,newName=try p.duplicateMacro(named:name);profile=p;refreshMacroPicker();macroPicker.selectItem(withTitle:newName);chooseMacro();update();message.stringValue="已复制宏；原绑定保留，副本尚未绑定或写入。"}catch{message.stringValue=error.localizedDescription}}
    @objc func clearMacros(){guard var p=profile else{return};do{try p.clearMacros();profile=p;refreshMacroPicker();chooseMacro();update();message.stringValue="宏已从编辑区清空，原宏绑定键设为禁用；尚未写入，可撤销修改。"}catch{message.stringValue=error.localizedDescription}}
    @objc func unassignMacro(){guard !busy,var p=profile,let key=keyboardLayout().first(where:{$0.id==selected}),let slot=CherryMatrix.slot(key) else{return};do{try p.unassignMacro(from:slot);profile=p;loadSelectedAssignment();update();message.stringValue="已解除 \(key.label) 的宏绑定并设为禁用；宏库保留，尚未写入键盘。"}catch{message.stringValue=error.localizedDescription}}
    @objc func deleteMacro(){guard var p=profile,macroPicker.indexOfSelectedItem>0 else{return};do{let name=p.macros[macroPicker.indexOfSelectedItem-1].name;try p.removeMacro(named:name);profile=p;refreshMacroPicker();chooseMacro();update();message.stringValue="宏已从编辑区删除；关联按键设为禁用，尚未写入键盘。"}catch{message.stringValue=error.localizedDescription}}
    @objc func editPollingDraft(){
        guard !busy else{return}
        do{
            guard var draft=profile,let template=draft.windowsTemplateJSON,let words=try WindowsProfile.systemStageWords(WindowsProfile.templateRoot(Data(template.utf8)))else{throw HardwareError(message:"请先导入包含设备设置的 Windows 官方 JSON。")}
            let picker=NSPopUpButton(frame:NSRect(x:0,y:0,width:300,height:28));picker.addItems(withTitles:["125 Hz","250 Hz","500 Hz","1000 Hz"])
            if words[3]<=3{picker.selectItem(at:Int(words[3]))}else{picker.addItem(withTitle:"保留原值（\(words[3])）");picker.selectItem(at:4)}
            let alert=NSAlert();alert.messageText="官方回报率草稿";alert.informativeText="只修改官方配置文件里的 USB 回报率。保存后可在配置与备份导出；尚未写入键盘。无线回报率及其他设备设置沿用模板。";alert.accessoryView=picker;alert.addButton(withTitle:"保存草稿");alert.addButton(withTitle:"取消")
            guard alert.runModal()==NSApplication.ModalResponse.alertFirstButtonReturn,picker.indexOfSelectedItem<4 else{return}
            let data=try WindowsProfile.encodePollingDraft(Data(template.utf8),index:picker.indexOfSelectedItem);draft.windowsTemplateJSON=String(decoding:data,as:UTF8.self);try draft.validate();profile=draft
            message.stringValue="回报率已保存到官方配置草稿，尚未写入键盘。";update()
        }catch{message.stringValue=error.localizedDescription}
    }
    @objc func exportWindowsProfile(){
        guard !busy,let p=profile else{message.stringValue="请先读取或导入配置。";return}
        do{
            guard let template=p.windowsTemplateJSON else{throw HardwareError(message:"请先导入本型号的 Windows 官方 JSON，作为导出模板。")}
            let keyData:Data;let includesText:Bool
            #if CHERRY_MACRO_PRODUCT
            if let hostTextJSON {
                guard let baseline else{throw HardwareError(message:"合并文本导出需要当前读取基线，请先读取键盘。")}
                keyData=try WindowsProfile.encodeKeysMacrosAndText(p,template:Data(template.utf8),textConfiguration:hostTextJSON,baseline:baseline);includesText=true
            }else{keyData=try WindowsProfile.encodeKeysAndMacros(p,template:Data(template.utf8));includesText=false}
            #else
            keyData=try WindowsProfile.encodeKeysAndMacros(p,template:Data(template.utf8));includesText=false
            #endif
            let data=try WindowsProfile.encodeProfileLightingDraft(p,template:keyData)
            let lightingNote=p.lightingColorEncoding == .officialRGB ? "包含当前灯效草稿":"包含当前内置灯效；逐键配色沿用导入模板"
            let panel=NSSavePanel();panel.nameFieldStringValue="CHERRY-配置草稿.json"
            panel.beginSheetModal(for:window!){[weak self] result in
                guard result == .OK,let url=panel.url else{return}
                do{try data.write(to:url,options:.atomic);self?.message.stringValue=includesText ? "已合并导出 Windows 格式键位、宏与文本；\(lightingNote)；设备设置沿用导入模板。":"已导出 Windows 格式键位与宏；\(lightingNote)；设备设置沿用导入模板。"}
                catch{self?.message.stringValue=error.localizedDescription}
            }
        }catch{message.stringValue=error.localizedDescription}
    }
    @objc func exportProfile(){
        guard var p=profile else{message.stringValue="请先读取或导入配置。";return}
        #if CHERRY_MACRO_PRODUCT
        p.hostTextJSON=hostTextJSON.map{String(decoding:$0,as:UTF8.self)}
        #endif
        do{
            let data=try p.encoded(),panel=NSSavePanel();panel.nameFieldStringValue="CherryMac-键盘配置.json"
            panel.beginSheetModal(for:window!){[weak self] result in
                guard result == .OK,let url=panel.url else{return}
                do{try data.write(to:url,options:.atomic);self?.message.stringValue="配置已导出，包含选中的文本定义；文本恢复记录需在文本页另行导出。"}catch{self?.message.stringValue=error.localizedDescription}
            }
        }catch{message.stringValue=error.localizedDescription}
    }
    func loadImport(_ data:Data)throws {
        guard !busy else{throw HardwareError(message:"请等待键盘操作完成。")}
        guard data.count<=3_000_000 else{throw HardwareError(message:"配置文件超过 3 MB。")}
        let next:HardwareProfile;let summary:String
        if WindowsProfile.isOfficial(data){
            guard let baseline else{throw HardwareError(message:"导入 Windows 配置前，请先读取当前 USB 键盘，以保留原配置和宏区。")}
            #if CHERRY_MACRO_PRODUCT
            let imported=try WindowsProfile.decode(data,baseline:baseline,deferHostText:true,lightingMapping:profile?.lightingMapping)
            #else
            let imported=try WindowsProfile.decode(data,baseline:baseline,lightingMapping:profile?.lightingMapping)
            #endif
            next=imported.profile;summary=imported.summary
        }else{next=try HardwareProfile.decode(data);summary="配置已载入编辑区，尚未写入键盘。"}
        suspendHostTextForConfiguration()
        #if CHERRY_MACRO_PRODUCT
        hostTextJSON=next.hostTextJSON.map{Data($0.utf8)}
        hostTextFile.stringValue=hostTextJSON==nil ? "本配置未包含文本定义":"导入的文本定义 · 仅载入，尚未安装或启用"
        #endif
        profile=next;recordingPreference=nil;message.stringValue=summary;loadLighting();refreshMacroPicker();loadSelectedAssignment();update()
    }
    @objc func importProfile(){
        let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        panel.beginSheetModal(for:window!){[weak self] result in
            guard result == .OK,let url=panel.url,let self else{return}
            do{try self.loadImport(Data(contentsOf:url))}catch{self.message.stringValue=error.localizedDescription}
        }
    }
    @objc func importDefaultTemplate(){
        guard !busy,baseline != nil,let parent=window else{message.stringValue="请先读取键盘，再载入官方默认草稿。";return}
        let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        panel.beginSheetModal(for:parent){[weak self] response in
            guard response == .OK,let url=panel.url,let self else{return}
            do{
                guard !self.busy else{throw HardwareError(message:"请等待键盘操作完成。")}
                let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize
                guard let size,size<=16_000_000 else{throw HardwareError(message:"默认文件超过 16 MB。")}
                let template=try WindowsProfile.extractDefaultTemplate(Data(contentsOf:url))
                let alert=NSAlert();alert.messageText="载入官方默认草稿？";alert.informativeText="这会替换当前编辑区，并关闭文本输入服务。请先导出需要保留的配置。默认键位、灯效与文件设置只载入草稿，原始宏存储保留；不会写入键盘，完整恢复默认尚未开放。";alert.addButton(withTitle:"取消，保留编辑区");alert.addButton(withTitle:"已保存，载入草稿")
                guard alert.runModal()==NSApplication.ModalResponse.alertSecondButtonReturn else{return}
                try self.loadImport(template)
                self.message.stringValue="官方默认配置已载入编辑区，原始宏存储保留；尚未写入，完整恢复默认仍待补齐。"
            }catch{self.message.stringValue=error.localizedDescription}
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
    @objc func discardDraft(){guard let baseline else{return};suspendHostTextForConfiguration();recordingPreference=nil;profile=recalledMacroProfile(baseline) ?? (try? HardwareProfile.fromHardware(baseline)) ?? HardwareProfile(snapshot:baseline);profile?.lightingMapping=baselineLightingMapping;message.stringValue="已恢复到最近读取的配置。";loadLighting();refreshMacroPicker();loadSelectedAssignment();update()}
    func windowWillClose(_ notification:Notification){
        #if CHERRY_MACRO_PRODUCT
        stopHostTextBridge()
        #else
        suspendHostTextForConfiguration()
        #endif
    }
    @objc func installApplicationShortcut(){
        guard !busy,var draft=profile,let key=keyboardLayout().first(where:{$0.id==selected}),let slot=CherryMatrix.slot(key),KeymapWriteAuthorization.editableSlots.contains(slot)else{message.stringValue="请选择可配置按键，完成当前操作后再安装。";return}
        let shortcut:MacApplicationShortcut
        switch actionPicker.indexOfSelectedItem {
        case 2:shortcut = .calculator
        case 10:shortcut = .finder
        case 11:shortcut = .mail
        case 12:shortcut = .music
        case 9:
            switch mediaPicker.selectedItem?.tag {case 0:shortcut = .music;case 15:shortcut = .finder;case 16:shortcut = .calculator;case 17:shortcut = .mail;default:message.stringValue="请选择计算器、我的电脑、邮件或媒体播放器。";return}
        default:message.stringValue="请选择计算器、Finder、邮件或音乐的启动功能。";return
        }
        do{try ApplicationShortcutService.install(shortcut)
            draft.snapshot.keymap.replaceSubrange(slot*3..<slot*3+3,with:shortcut.record);draft.macroBindings?.removeValue(forKey:slot);draft.macroModes?.removeValue(forKey:slot)
            profile=draft;loadSelectedAssignment();update();message.stringValue="已安装打开\(shortcut.title)的系统快捷操作，并保存到编辑区。尚未写入键盘；请核对后点击写入键位。"
        }catch{message.stringValue=error.localizedDescription}
    }
    @objc func installCalculator(){guard !busy else{return};do{try CalculatorService.install();message.stringValue="已安装系统快捷操作。把目标键设为“打开系统计算器”，保存到编辑区后点击“写入键位”。"}catch{message.stringValue=error.localizedDescription}}
}

// An explicit sheet records AppKit events delivered to its focus area only.
// No global event monitors, accessibility hooks or hardware access.
final class MacroRecordingArea:NSView {
    weak var owner:MacroRecordingSheet?
    override var acceptsFirstResponder:Bool{true}
    override func draw(_ dirtyRect:NSRect){NSColor.controlBackgroundColor.setFill();bounds.fill();let text=owner?.recorder == nil ? "录制区 · 点击开始后在此操作":"正在录制 · 松开全部按键后停止";(text as NSString).draw(at:NSPoint(x:16,y:bounds.midY),withAttributes:[.font:NSFont.systemFont(ofSize:15),.foregroundColor:NSColor.labelColor])}
    override func keyDown(with event:NSEvent){owner?.keyboard(event,pressed:true)}
    override func keyUp(with event:NSEvent){owner?.keyboard(event,pressed:false)}
    override func flagsChanged(with event:NSEvent){owner?.modifier(event)}
    override func performKeyEquivalent(with event:NSEvent)->Bool{guard owner?.recorder != nil else{return false};owner?.keyboard(event,pressed:true);return true}
    override func mouseDown(with event:NSEvent){window?.makeFirstResponder(self);owner?.mouse(event,pressed:true)}
    override func mouseUp(with event:NSEvent){owner?.mouse(event,pressed:false)}
    override func rightMouseDown(with event:NSEvent){owner?.mouse(event,pressed:true)}
    override func rightMouseUp(with event:NSEvent){owner?.mouse(event,pressed:false)}
    override func otherMouseDown(with event:NSEvent){owner?.mouse(event,pressed:true)}
    override func otherMouseUp(with event:NSEvent){owner?.mouse(event,pressed:false)}
    override func scrollWheel(with event:NSEvent){owner?.unsupportedMouseEvent()}
}
final class MacroRecordingSheet:NSWindowController,NSWindowDelegate {
    let name:String
    let originalSteps:[KeyboardMacro.Step]
    let selectedStep:Int?
    let placement=NSPopUpButton()
    let completion:(KeyboardMacro?)->Void
    let timing=NSPopUpButton(frame:.zero,pullsDown:false),delay=NSTextField(string:"30")
    let mouseOption=NSButton(checkboxWithTitle:"记录鼠标按钮（开启后也会录入切换应用的点击）",target:nil,action:nil)
    let globalOption=NSButton(checkboxWithTitle:"同时录制其他应用中的操作（需要辅助功能权限）",target:nil,action:nil)
    private var globalMonitor:Any?
    let start=NSButton(title:"开始录制",target:nil,action:nil),stop=NSButton(title:"停止并采用",target:nil,action:nil),cancelButton=NSButton(title:"取消",target:nil,action:nil)
    let area=MacroRecordingArea(frame:NSRect(x:20,y:82,width:520,height:112)),status=NSTextField(labelWithString:"只记录本窗口事件；系统占用的快捷键请手动添加。")
    var recorder:MacroRecorder?
    var closed=false
    static let modifiers:[UInt16:(UInt8,UInt)] = [59:(224,1),56:(225,2),58:(226,32),55:(227,8),62:(228,8192),60:(229,4),61:(230,64),54:(231,16)]
    static let nativeUsages:[UInt16:UInt8] = Dictionary(uniqueKeysWithValues:Dictionary(grouping:hidToMacKey.filter{$0.key>=4 && $0.key<=231},by:{$0.value}).compactMap{code,entries in entries.count==1 ? (code,UInt8(entries[0].key)):nil})
    init(name:String,originalSteps:[KeyboardMacro.Step]=[],selectedStep:Int?=nil,completion:@escaping(KeyboardMacro?)->Void){
        self.name=name;self.originalSteps=originalSteps;self.selectedStep=selectedStep;self.completion=completion
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:560,height:404),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        panel.title="录制宏";super.init(window:panel);panel.delegate=self
        let root=panel.contentView!;root.wantsLayer=true;root.layer?.backgroundColor=NSColor.windowBackgroundColor.cgColor;area.owner=self
        let intro=NSTextField(wrappingLabelWithString:"默认只录制下方区域；勾选其他应用录制后可切换应用。操作会正常执行，请避开密码等敏感内容，完成后回到此处停止。")
        intro.frame=NSRect(x:20,y:348,width:520,height:40);root.addSubview(intro)
        timing.addItems(withTitles:["实际间隔","固定间隔","忽略间隔"]);timing.frame=NSRect(x:20,y:310,width:180,height:28);delay.frame=NSRect(x:216,y:310,width:80,height:26);root.addSubview(timing);root.addSubview(delay)
        let unit=NSTextField(labelWithString:"毫秒（0–60000）");unit.frame=NSRect(x:306,y:310,width:190,height:24);root.addSubview(unit)
        placement.addItems(withTitles:["替换全部步骤","末尾追加","所选步骤前插入","所选步骤后插入"]);placement.frame=NSRect(x:20,y:274,width:260,height:28);placement.setAccessibilityLabel("录制片段的插入位置");root.addSubview(placement)
        let selected=selectedStep.flatMap{originalSteps.indices.contains($0) ? $0:nil}
        placement.item(at:2)?.isEnabled=selected != nil;placement.item(at:3)?.isEnabled=selected != nil
        let context=NSTextField(labelWithString:selected.map{"所选步骤 \($0+1) · 原有 \(originalSteps.count) 步"} ?? "原有 \(originalSteps.count) 步");context.frame=NSRect(x:298,y:274,width:242,height:24);root.addSubview(context)
        globalOption.frame=NSRect(x:20,y:240,width:520,height:24);root.addSubview(globalOption)
        mouseOption.frame=NSRect(x:20,y:204,width:520,height:24);root.addSubview(mouseOption);root.addSubview(area)
        status.frame=NSRect(x:20,y:50,width:520,height:24);root.addSubview(status)
        for (index,button) in [start,stop,cancelButton].enumerated(){button.frame=NSRect(x:20+index*172,y:10,width:160,height:30);button.bezelStyle = .rounded;button.target=self;root.addSubview(button)}
        start.action=#selector(begin);stop.action=#selector(finish);cancelButton.action=#selector(cancel);stop.isEnabled=false
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    static func clock()->Int{Int(ProcessInfo.processInfo.systemUptime*1000)}
    func controls(){let active=recorder != nil;start.isEnabled = !active;stop.isEnabled=active;timing.isEnabled = !active;delay.isEnabled = !active;mouseOption.isEnabled = !active;globalOption.isEnabled = !active;placement.isEnabled = !active;area.needsDisplay=true}
    @objc func begin(){beginRecording(modifierFlags:NSEvent.modifierFlags)}
    func beginRecording(modifierFlags:NSEvent.ModifierFlags,globalAccessGranted:()->Bool={AXIsProcessTrusted()}){
        guard recorder == nil,!closed else{return}
        do{
            guard modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty else{throw HardwareError(message:"请先松开修饰键，再开始录制。")}
            guard let value=Int(delay.stringValue)else{throw HardwareError(message:"请输入固定间隔毫秒。")}
            if globalOption.state == .on {
                guard globalAccessGranted() else{throw HardwareError(message:"请在系统设置 → 隐私与安全性 → 辅助功能允许此 App，然后重新打开；也可取消勾选，只录制下方区域。")}
            }
            recorder=try MacroRecorder(timing:[.actual,.fixed,.ignore][max(0,timing.indexOfSelectedItem)],fixedMilliseconds:value,startedMilliseconds:Self.clock())
            if globalOption.state == .on {
                var mask:NSEvent.EventTypeMask=[.keyDown,.keyUp,.flagsChanged]
                if mouseOption.state == .on {mask.formUnion([.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp,.scrollWheel])}
                guard let monitor=NSEvent.addGlobalMonitorForEvents(matching:mask,handler:{[weak self] event in self?.externalEvent(event)}) else{
                    throw HardwareError(message:"无法开启其他应用录制；请检查权限，或使用下方录制区。")
                }
                globalMonitor=monitor
            }
            controls();status.stringValue=globalOption.state == .on ? "正在录制其他应用和下方区域；完成后回来停止":"0 个事件";window?.makeFirstResponder(area)
        }catch{discardRecording(error.localizedDescription)}
    }
    func externalEvent(_ event:NSEvent){
        guard recorder != nil,!closed,globalOption.state == .on else{return}
        switch event.type {
        case .keyDown:keyboard(event,pressed:true)
        case .keyUp:keyboard(event,pressed:false)
        case .flagsChanged:modifier(event)
        case .leftMouseDown,.rightMouseDown,.otherMouseDown:mouse(event,pressed:true)
        case .leftMouseUp,.rightMouseUp,.otherMouseUp:mouse(event,pressed:false)
        case .scrollWheel:unsupportedMouseEvent()
        default:break
        }
    }
    private func removeGlobalMonitor(){if let monitor=globalMonitor{NSEvent.removeMonitor(monitor);globalMonitor=nil}}
    func discardRecording(_ message:String){removeGlobalMonitor();recorder?.cancel();recorder=nil;controls();status.stringValue=message}
    deinit{if let monitor=globalMonitor{NSEvent.removeMonitor(monitor)}}
    func observe(_ usage:UInt8,kind:KeyboardMacro.Step.Kind?=nil,pressed:Bool,repeatEvent:Bool=false){guard recorder != nil else{return};do{try recorder!.observe(usage:usage,kind:kind,pressed:pressed,milliseconds:Self.clock(),repeatEvent:repeatEvent);status.stringValue="\(recorder!.steps.count) 个事件"}catch{discardRecording(error.localizedDescription)}}
    func keyboard(_ event:NSEvent,pressed:Bool){guard recorder != nil else{return};guard let usage=Self.nativeUsages[event.keyCode]else{discardRecording("此按键编码不明确，请手动添加；录制已取消。");return};observe(usage,pressed:pressed,repeatEvent:event.isARepeat)}
    func modifier(_ event:NSEvent){guard let (usage,mask)=Self.modifiers[event.keyCode]else{return};observe(usage,pressed:event.modifierFlags.rawValue & mask != 0)}
    func unsupportedMouseEvent(){guard recorder != nil,mouseOption.state == .on else{return};discardRecording("滚轮或其他鼠标事件尚未支持，录制已取消；原步骤保留。")}
    func mouse(_ event:NSEvent,pressed:Bool){guard mouseOption.state == .on else{return};guard let usage=([0:UInt8(1),1:2,2:4,3:8,4:16])[event.buttonNumber] else{unsupportedMouseEvent();return};observe(usage,kind:.mouse,pressed:pressed)}
    @objc func finish(){do{guard var draft=recorder else{return};let index:Int?
        switch placement.indexOfSelectedItem{case 0:index=nil;case 1:index=originalSteps.count;default:guard let selectedStep,originalSteps.indices.contains(selectedStep) else{throw HardwareError(message:"请重新选择录制插入位置。")};index=selectedStep+(placement.indexOfSelectedItem==3 ? 1:0)}
        let macro=try draft.finish(name:name,originalSteps:originalSteps,insertionIndex:index);complete(macro)
    }catch{status.stringValue=error.localizedDescription;window?.makeFirstResponder(area)}}
    @objc func cancel(){recorder?.cancel();complete(nil)}
    func complete(_ macro:KeyboardMacro?){guard !closed else{return};removeGlobalMonitor();recorder?.cancel();recorder=nil;closed=true;if let panel=window{panel.sheetParent?.endSheet(panel);panel.orderOut(nil)};completion(macro)}
    func windowShouldClose(_ sender:NSWindow)->Bool{cancel();return false}
    func windowDidResignKey(_ notification:Notification){guard recorder != nil,!closed,globalOption.state != .on else{return};discardRecording("窗口失去焦点，录制已取消；原步骤保留。")}
}
