import AppKit

extension HardwareWindowController {
    @objc func inspectLightingRecovery(){
        guard !busy else{return}
        let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do{
            let data=try Data(contentsOf:url);guard data.count<=3_000_000 else{throw HardwareError(message:"灯效恢复记录超过 3 MB。")}
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            let root=try JSONSerialization.jsonObject(with:data) as? [String:Any]
            let stateCode:String,recoveryCode:String,traceReview:WindowsProfile.OfficialLightingPlan.TraceReview,encoded:Data
            if root?["format"] as? String=="CherryMacLightingRestoreAttempt" {
                let attempt=try JSONDecoder().decode(WindowsProfile.OfficialLightingPlan.RecoveryPlan.Attempt.self,from:data),review=try attempt.assess()
                stateCode=review.status;recoveryCode=review.recoveryStatus;traceReview=review.traceReview;encoded=try encoder.encode(review)
            } else {
                let record=try JSONDecoder().decode(WindowsProfile.OfficialLightingPlan.RecoveryRecord.self,from:data),review=try record.assess()
                stateCode=review.status;recoveryCode=review.recoveryStatus;traceReview=review.traceReview;encoded=try encoder.encode(review)
            }
            let state=["alreadyMatched":"恢复前已与备份一致","readbackMatched":"读回符合目标","readbackMismatch":"读回未符合目标","incomplete":"日志未完成","failed":"操作失败"][stateCode] ?? stateCode
            let recovery=["available":"可分析原始数据恢复","unchanged":"配置与备份一致","unrecognized":"存在无法识别的配置变化","unavailable":"没有完整读回"][recoveryCode] ?? recoveryCode
            message.stringValue="\(state)；\(recovery)。有效回复 \(traceReview.acceptedReports)/\(traceReview.expectedReports)。未修改键盘。"
            let save=NSSavePanel();save.nameFieldStringValue="CherryMac-灯效恢复分析.json"
            if save.runModal() == .OK,let output=save.url {
                guard output.standardizedFileURL.resolvingSymlinksInPath() != url.standardizedFileURL.resolvingSymlinksInPath() else{throw HardwareError(message:"分析文件不能覆盖原始恢复记录。")}
                try encoded.write(to:output,options:.atomic)
            }
        }catch{message.stringValue=error.localizedDescription}
    }
    @objc func reviewLightingDraft(){
        guard !busy else{return}
        do{
            guard baselineWasRead,let baseline,let profile else{throw HardwareError(message:"请先读取键盘，保存灯效到编辑区后再核对。")}
            let review=try WindowsProfile.reviewLightingDraft(profile,baseline:baseline)
            let alert=NSAlert();alert.messageText="核对灯效写入"
            let mode=modes.first(where:{$0.1==review.target.parameters[1]})?.0 ?? "未知模式"
            alert.informativeText="模式：\(mode)；亮度：\(review.target.parameters[2])/4。\n逐键颜色将改变 \(review.changedColorSlots.count) 个位置；灯效参数\(review.changedParameterOffsets.isEmpty ? "保持不变":"将更新")。\n此核对仅生成计划，尚未写入键盘。按键与宏保持读回配置。"
            alert.addButton(withTitle:"导出计划…");alert.addButton(withTitle:"返回编辑")
            guard alert.runModal()==NSApplication.ModalResponse.alertFirstButtonReturn else{return}
            let panel=NSSavePanel();panel.nameFieldStringValue="CherryMac-灯效写入核对.json"
            guard panel.runModal() == .OK,let output=panel.url else{return}
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            try encoder.encode(review).write(to:output,options:.atomic)
            message.stringValue="已导出灯效写入核对计划，尚未写入键盘。"
        }catch{message.stringValue=error.localizedDescription}
    }
    func buildLighting(_ pane:NSView){
        let tabs=NSTabView();tabs.tabViewType = .noTabsNoBorder;lightTabView=tabs;place(tabs,0,44,930,246,in:pane)
        for title in ["内置灯效","逐键配色"]{let item=NSTabViewItem(identifier:title);item.label=title;item.view=FlippedView();tabs.addTabViewItem(item)}
        for (index,title) in ["内置灯效","逐键配色"].enumerated(){let b=HardwareNavigationButton(title:title,target:self,action:#selector(chooseLightTab(_:)));b.tag=index;b.isBordered=false;b.setButtonType(.toggle);place(b,8+CGFloat(index)*140,4,130,30,in:pane);lightTabButtons.append(b)}
        let review=button("核对灯效写入…",#selector(reviewLightingDraft));review.toolTip="先保存到编辑区再核对；仅导出计划。";place(review,690,4,210,30,in:pane)
        let builtins=tabs.tabViewItems[0].view!
        place(label("模式"),8,12,72,24,in:builtins)
        modePicker.addItems(withTitles:modes.map{$0.0});controls.append(modePicker);place(modePicker,92,8,277,28,in:builtins)
        place(label("亮度"),8,57,72,24,in:builtins);place(brightness,92,53,277,28,in:builtins)
        place(label("慢 ← 速度 → 快",12),8,103,125,24,in:builtins);place(speed,151,99,218,28,in:builtins)
        for slider in [brightness,speed]{slider.numberOfTickMarks=5;slider.allowsTickMarkValuesOnly=true;controls.append(slider)}
        place(label("方向"),431,12,95,24,in:builtins)
        lightDirection.addItems(withTitles:["保留方向","正向","反向"]);controls.append(lightDirection);place(lightDirection,549,8,215,28,in:builtins)
        place(label("颜色选项"),431,57,95,24,in:builtins)
        lightRainbow.addItems(withTitles:["保留颜色选项","单色","彩虹"]);controls.append(lightRainbow);place(lightRainbow,549,53,215,28,in:builtins)
        place(label("单色颜色"),431,105,95,24,in:builtins);controls.append(globalLightColor);place(globalLightColor,549,98,55,32,in:builtins)
        place(button("使用此颜色",#selector(stageGlobalLightColor)),625,99,139,30,in:builtins)
        place(button("保存灯效到编辑区",#selector(stageLights)),8,159,234,30,in:builtins)
        place(label("不同模式可能忽略不适用的速度、方向和颜色设置。",12),8,206,832,27,in:builtins)
        let colors=tabs.tabViewItems[1].view!
        controls.append(lightMultiple);place(lightMultiple,8,7,76,25,in:colors)
        lightRegion.addItems(withTitles:CherryLighting.regions);controls.append(lightRegion);place(lightRegion,94,4,163,28,in:colors)
        place(button("选择按键",#selector(selectLightRegion)),276,4,108,28,in:colors);place(lightCount,407,9,140,22,in:colors)
        place(label("颜色"),8,57,65,23,in:colors);place(color,79,49,55,31,in:colors)
        color.target=self;color.action=#selector(lightColorChanged);controls.append(color)
        place(label("HEX"),155,57,38,23,in:colors);lightHex.tag=104;lightHex.delegate=self;controls.append(lightHex);place(lightHex,200,53,113,25,in:colors)
        for index in 0..<3 {
            place(label(["R","G","B"][index]),337+CGFloat(index)*110,57,20,23,in:colors)
            let field=lightRGB[index];field.tag=101+index;field.delegate=self;controls.append(field);place(field,360+CGFloat(index)*110,53,75,25,in:colors)
        }
        place(label("颜色强度",12),8,105,75,23,in:colors);lightStrength.target=self;lightStrength.action=#selector(lightStrengthChanged);controls.append(lightStrength);place(lightStrength,94,100,168,25,in:colors)
        place(lightStrengthLabel,275,105,51,23,in:colors)
        lightPattern.addItems(withTitles:CherryLighting.patterns);controls.append(lightPattern);place(lightPattern,337,99,188,28,in:colors)
        place(label("渐变终点",12),548,105,66,23,in:colors);endColor.color = .systemBlue;controls.append(endColor);place(endColor,625,97,55,31,in:colors)
        place(button("应用到所选键",#selector(stageColor)),8,158,192,30,in:colors)
        place(button("熄灭所选键",#selector(stageLightOff)),218,158,172,30,in:colors)
        place(label("⌘ 点击可多选。逐键配色为静态，切换页面不会丢失已保存的编辑。",12),8,206,866,27,in:colors)
        chooseLightTab(lightTabButtons[0])
    }
    @objc func chooseLightTab(_ sender:NSButton){
        guard (0..<2).contains(sender.tag) else{return};lightTabView?.selectTabViewItem(at:sender.tag)
        for b in lightTabButtons{b.state=b.tag==sender.tag ? .on:.off;b.needsDisplay=true}
    }
    func rgb(_ value:NSColor)->LightRGB {
        let color=value.usingColorSpace(.sRGB) ?? NSColor.white
        return LightRGB(UInt8((max(0,min(1,color.redComponent))*255).rounded()),UInt8((max(0,min(1,color.greenComponent))*255).rounded()),UInt8((max(0,min(1,color.blueComponent))*255).rounded()))
    }
    func setLightColor(_ value:LightRGB){
        color.color=NSColor(srgbRed:CGFloat(value.red)/255,green:CGFloat(value.green)/255,blue:CGFloat(value.blue)/255,alpha:1)
        lightHex.stringValue=value.hex
        for (field,byte) in zip(lightRGB,value.bytes){field.stringValue=String(byte)}
        lightStrength.doubleValue=value.strength;lightStrengthLabel.stringValue="\(Int(value.strength.rounded()))%";colorEditSource=0
    }
    func readLightColor()throws->LightRGB {
        if colorEditSource==2{return try LightRGB(hex:lightHex.stringValue)}
        if colorEditSource==1 {
            let values=try lightRGB.map{field->UInt8 in
                guard let value=Int(field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)),(0...255).contains(value)else{throw HardwareError(message:"R、G、B 必须是 0–255 的整数。")};return UInt8(value)
            };return LightRGB(values[0],values[1],values[2])
        }
        return rgb(color.color)
    }
    func loadLightColor(){
        guard let key=keyboardLayout().first(where:{$0.id==selected}),let keySlot=CherryMatrix.slot(key),let p=profile,let slot=p.colorSlot(keySlot),let colors=p.snapshot.colors else{return}
        setLightColor(LightRGB(colors[slot*3],colors[slot*3+1],colors[slot*3+2]))
    }
    func controlTextDidChange(_ notification:Notification){
        if let field=notification.object as? NSTextField,field===macroName || field===macroRepeat{updateMacroSummary();return}
        guard let field=notification.object as? NSTextField else{return}
        if field.tag==104{colorEditSource=2}else if (101...103).contains(field.tag){colorEditSource=1}
    }
    @objc func lightColorChanged(){setLightColor(rgb(color.color))}
    @objc func lightStrengthChanged(){
        do{setLightColor(try readLightColor().withStrength(lightStrength.doubleValue))}catch{message.stringValue=error.localizedDescription}
    }
    @objc func selectLightRegion(){
        let region=lightRegion.indexOfSelectedItem
        guard region>0 else{return}
        lightSelection=CherryLighting.region(region,keys:keyboardLayout())
        if let first=keyboardLayout().first(where:{lightSelection.contains($0.id)}){selected=first.id}
        update();loadLightColor()
    }
    @objc func stageColor(){
        guard !busy,var draft=profile,let colors=draft.snapshot.colors else{message.stringValue="请先读取键盘。";return}
        do{
            let start=try readLightColor()
            draft.snapshot.colors=try CherryLighting.paint(colors,keys:keyboardLayout(),selected:lightSelection,pattern:lightPattern.indexOfSelectedItem,start:start,end:rgb(endColor.color),lightingMapping:draft.lightingMapping)
            draft.snapshot.parameters[1]=8;profile=draft;modePicker.selectItem(at:1)
            message.stringValue="已为 \(lightSelection.count) 键加入配色，并选择自定义模式。编辑仅用于预览，尚未写入键盘。"
            update();loadLightColor()
        }catch{message.stringValue=error.localizedDescription}
    }
    @objc func stageLightOff(){
        guard !busy,var draft=profile,let colors=draft.snapshot.colors else{message.stringValue="请先读取键盘。";return}
        do{draft.snapshot.colors=try CherryLighting.paint(colors,keys:keyboardLayout(),selected:lightSelection,pattern:0,start:LightRGB(0,0,0),end:LightRGB(0,0,0),lightingMapping:draft.lightingMapping)
            draft.snapshot.parameters[1]=8;profile=draft;modePicker.selectItem(at:1);update();loadLightColor()
            message.stringValue="已将所选 \(lightSelection.count) 键设为熄灭。编辑仅用于预览，尚未写入键盘。"
        }catch{message.stringValue=error.localizedDescription}
    }
    @objc func stageLights(){
        guard !busy,var draft=profile,(0..<modes.count).contains(modePicker.indexOfSelectedItem)else{message.stringValue="请先读取键盘。";return}
        draft.snapshot.parameters[1]=modes[modePicker.indexOfSelectedItem].1
        draft.snapshot.parameters[2]=UInt8(Int(brightness.doubleValue.rounded()))
        draft.snapshot.parameters[3]=UInt8(4-Int(speed.doubleValue.rounded()))
        if lightDirection.indexOfSelectedItem>0{draft.snapshot.parameters[4]=UInt8(lightDirection.indexOfSelectedItem-1)}
        if lightRainbow.indexOfSelectedItem>0{draft.snapshot.parameters[5]=UInt8(lightRainbow.indexOfSelectedItem-1)}
        profile=draft;message.stringValue="已加入模式、亮度和速度设置。编辑仅用于预览，尚未写入键盘。";update()
    }
    @objc func stageGlobalLightColor(){
        guard !busy,var draft=profile else{message.stringValue="请先读取键盘。";return}
        let value=rgb(globalLightColor.color);draft.snapshot.parameters.replaceSubrange(6..<9,with:value.bytes);draft.snapshot.parameters[5]=0
        profile=draft;lightRainbow.selectItem(at:1);message.stringValue="已把内置灯效颜色保存到编辑区，尚未写入。"
    }
}
