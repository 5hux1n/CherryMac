import AppKit

extension HardwareWindowController {
    @discardableResult
    func rememberRawLighting(_ draft:HardwareProfile,current:HardwareSnapshot)throws->Bool {
        guard let value=try RawLightingMetadata.capture(draft,current:current) else{return false}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let data=try encoder.encode(value)
        try FileManager.default.createDirectory(at:backupDirectory,withIntermediateDirectories:true)
        let url=backupDirectory.appendingPathComponent("LightingMetadata-\(UUID().uuidString).json")
        try data.write(to:url,options:.atomic)
        guard try Data(contentsOf:url)==data else{throw HardwareError(message:"原始配色资料保存校验失败，请导出当前草稿保存。")}
        return true
    }
    func recalledRawLighting(_ profile:HardwareProfile)->HardwareProfile? {
        guard profile.lightingMapping != nil else{return nil}
        let files=(try? FileManager.default.contentsOfDirectory(at:backupDirectory,includingPropertiesForKeys:[.contentModificationDateKey,.fileSizeKey])) ?? []
        let candidates=files.filter{$0.lastPathComponent.hasPrefix("LightingMetadata-") && $0.pathExtension=="json"}.sorted{((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)}
        for url in candidates.prefix(128){
            guard let size=try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=100_000,
                  let data=try? Data(contentsOf:url),let value=try? JSONDecoder().decode(RawLightingMetadata.self,from:data),
                  let next=try? value.adopting(into:profile) else{continue}
            return next
        };return nil
    }
    @objc func saveRawLightingDraft(){
        guard !busy,baselineWasRead,let baseline,let draft=profile else{message.stringValue="请先读取键盘。";return}
        do{
            guard let mapping=baselineLightingMapping,draft.lightingMapping==mapping else{throw HardwareError(message:"请先读取实际 LED 映射；导入的映射资料不能替代本次读取。")}
            guard try rememberRawLighting(draft,current:baseline) else{throw HardwareError(message:"当前原始配色或灯效参数与最近读回不一致。尚未写入的草稿请在配置与备份中导出 JSON 保存。")}
            message.stringValue="已将与最近读回一致的原始配色保存到本机；下次读取并核对一致后可继续编辑。未写入键盘。"
        }catch{message.stringValue=error.localizedDescription}
    }
    @objc func newCustomLightingDraft(){
        guard !busy,baselineWasRead,baseline != nil,let current=profile else{message.stringValue="请先读取键盘，取得完整配置和 LED 映射。";return}
        do{
            let next=try WindowsProfile.newCustomLightingDraft(current)
            let alert=NSAlert();alert.messageText="新建逐键配色？";alert.informativeText="当前颜色草稿将清空，并从全部熄灭开始。请先导出需要保留的配色。按键、宏、文本和设备设置保留；不会写入键盘。"
            alert.addButton(withTitle:"取消，保留草稿");alert.addButton(withTitle:"新建空白配色")
            guard alert.runModal() == .alertSecondButtonReturn else{return}
            profile=next;loadLighting();loadLightColor();update()
            message.stringValue="已新建空白逐键配色。选择按键并应用颜色后核对计划；尚未写入键盘。"
        }catch{message.stringValue=error.localizedDescription}
    }
    @objc func importLightingDraft(){
        guard !busy,let current=profile else{message.stringValue="请先读取键盘。";return}
        let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do{
            let values=try url.resourceValues(forKeys:[.fileSizeKey]);guard let size=values.fileSize,size<=1_000_000 else{throw HardwareError(message:"官方配置超过 1 MB。")}
            let next=try WindowsProfile.importLightingDraft(Data(contentsOf:url),into:current)
            profile=next;loadLighting();update()
            message.stringValue="已仅载入官方灯效与配色到编辑区。键位、宏、文本及设备设置保留，尚未写入。"
        }catch{message.stringValue=error.localizedDescription}
    }
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
            let prompt=NSAlert();prompt.messageText="灯效恢复记录";prompt.informativeText=message.stringValue+"\n可导出恢复计划供后续核对；计划依据文件中的保存状态，实际恢复前仍需重新读取键盘。导出不会执行恢复。"
            prompt.addButton(withTitle:"导出分析…")
            let canPlan=["available","unchanged"].contains(recoveryCode)
            if canPlan{prompt.addButton(withTitle:"导出恢复计划…")}
            prompt.addButton(withTitle:"返回")
            let choice=prompt.runModal();let exportingPlan=canPlan && choice==NSApplication.ModalResponse.alertSecondButtonReturn
            guard choice==NSApplication.ModalResponse.alertFirstButtonReturn || exportingPlan else{return}
            let outputData=exportingPlan ? try encoder.encode(WindowsProfile.restorePlanFromRecord(data)):encoded
            let save=NSSavePanel();save.nameFieldStringValue=exportingPlan ? "CherryMac-灯效恢复计划.json":"CherryMac-灯效恢复分析.json"
            if save.runModal() == .OK,let output=save.url {
                guard output.standardizedFileURL.resolvingSymlinksInPath() != url.standardizedFileURL.resolvingSymlinksInPath() else{throw HardwareError(message:"分析文件不能覆盖原始恢复记录。")}
                try outputData.write(to:output,options:.atomic)
                message.stringValue=exportingPlan ? "已导出原始数据恢复计划，尚未执行；实际恢复前需要重新读取配置。":"已导出恢复分析，未修改键盘。"
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
            if let black=review.encodedBlackColorSlots,!black.isEmpty{alert.informativeText += "\n编码后有 \(black.count) 个原有颜色位置变为黑色，可提高全局亮度或颜色强度。这里核对配置数据，不保证实体灯光外观。"}
            alert.addButton(withTitle:"导出计划…");alert.addButton(withTitle:"返回编辑")
            guard alert.runModal()==NSApplication.ModalResponse.alertFirstButtonReturn else{return}
            let panel=NSSavePanel();panel.nameFieldStringValue="CherryMac-灯效写入核对.json"
            guard panel.runModal() == .OK,let output=panel.url else{return}
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            try encoder.encode(review).write(to:output,options:.atomic)
            message.stringValue="已导出灯效写入核对计划，尚未写入键盘。"
        }catch{message.stringValue=error.localizedDescription}
    }
    @objc func reviewDefaultLighting(){
        guard !busy,baselineWasRead,baseline != nil,profile?.lightingMapping != nil else{message.stringValue="请先读取完整配置和 LED 映射。";return}
        exportDefaultLightingReview(nil)
    }
    private func exportDefaultLightingReview(_ data:Data?){
        guard let baseline,let mapping=profile?.lightingMapping else{return}
        do{let review=try WindowsProfile.reviewDefaultLighting(data,baseline:baseline,mapping:mapping)
            let alert=NSAlert();alert.messageText="核对默认灯效";alert.informativeText="先重置默认配色表，再恢复\(data == nil ? "内置官方默认" : "所选文件")的灯效参数。颜色将改变 \(review.changedColorSlots.count) 个位置；参数将改变 \(review.changedParameterOffsets.count) 项。按键、宏及文本保持当前配置。这里只导出计划，不改变编辑草稿或键盘。"
            alert.addButton(withTitle:"导出计划…");alert.addButton(withTitle:"返回");alert.addButton(withTitle:"选择其他官方默认文件…")
            let response=alert.runModal()
            if response == .alertThirdButtonReturn{
                let input=NSOpenPanel();input.canChooseDirectories=false;input.allowsMultipleSelection=false
                guard input.runModal() == .OK,let url=input.url else{return}
                guard let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=16_000_000 else{throw HardwareError(message:"默认文件超过 16 MB。")}
                exportDefaultLightingReview(try Data(contentsOf:url));return
            }
            guard response == .alertFirstButtonReturn else{return}
            let output=NSSavePanel();output.nameFieldStringValue="CherryMac-默认灯效核对.json";guard output.runModal() == .OK,let destination=output.url else{return}
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];try encoder.encode(review).write(to:destination,options:.atomic)
            message.stringValue="已导出默认灯效计划，配色先于参数；尚未写入。可在灯效验收流程载入。"
        }catch{message.stringValue=error.localizedDescription}
    }
    func buildLighting(_ pane:NSView){
        let tabs=NSTabView();tabs.tabViewType = .noTabsNoBorder;lightTabView=tabs;place(tabs,0,44,930,246,in:pane)
        for title in ["内置灯效","逐键配色"]{let item=NSTabViewItem(identifier:title);item.label=title;item.view=FlippedView();tabs.addTabViewItem(item)}
        for (index,title) in ["内置灯效","逐键配色"].enumerated(){let b=HardwareNavigationButton(title:title,target:self,action:#selector(chooseLightTab(_:)));b.tag=index;b.isBordered=false;b.setButtonType(.toggle);place(b,8+CGFloat(index)*140,4,130,30,in:pane);lightTabButtons.append(b)}
        let review=button("核对灯效写入…",#selector(reviewLightingDraft));review.toolTip="读取后保存内置灯效即可核对，无需官方文件；逐键配色仍需原始颜色。仅导出计划。";place(review,690,4,210,30,in:pane)
        #if CHERRY_LIGHTING_TEST
        place(button("独立灯效验收…",#selector(openLightingAcceptance)),460,4,210,30,in:pane)
        #endif
        let builtins=tabs.tabViewItems[0].view!
        place(label("模式"),8,12,72,24,in:builtins)
        modePicker.addItems(withTitles:modes.map{$0.0});modePicker.target=self;modePicker.action=#selector(lightModeChanged);controls.append(modePicker);place(modePicker,92,8,277,28,in:builtins)
        place(label("亮度"),8,57,72,24,in:builtins);place(brightness,92,53,277,28,in:builtins)
        place(label("慢 ← 速度 → 快",12),8,103,125,24,in:builtins);place(speed,151,99,218,28,in:builtins)
        for slider in [brightness,speed]{slider.numberOfTickMarks=5;slider.allowsTickMarkValuesOnly=true;controls.append(slider)}
        place(label("方向"),431,12,95,24,in:builtins)
        lightDirection.addItems(withTitles:["保留方向","正向","反向"]);controls.append(lightDirection);place(lightDirection,549,8,215,28,in:builtins)
        place(label("颜色选项"),431,57,95,24,in:builtins)
        lightRainbow.addItems(withTitles:["保留颜色选项","单色","彩虹"]);controls.append(lightRainbow);place(lightRainbow,549,53,215,28,in:builtins)
        place(label("单色颜色"),431,105,95,24,in:builtins);controls.append(globalLightColor);place(globalLightColor,549,98,55,32,in:builtins)
        let colorButton=button("使用此颜色",#selector(stageGlobalLightColor));globalLightColorButton=colorButton;place(colorButton,625,99,139,30,in:builtins)
        place(button("保存灯效到编辑区",#selector(stageLights)),8,159,234,30,in:builtins)
        place(button("核对默认灯效…",#selector(reviewDefaultLighting)),258,159,162,30,in:builtins)
        place(button("仅导入官方灯效…",#selector(importLightingDraft)),431,159,260,30,in:builtins)
        lightModeHelp.font = .systemFont(ofSize:12);place(lightModeHelp,8,199,832,40,in:builtins)
        let colors=tabs.tabViewItems[1].view!
        place(button("新建逐键配色…",#selector(newCustomLightingDraft)),630,4,234,28,in:colors)
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
        let paintButton=button("应用到所选键",#selector(stageColor)),offButton=button("熄灭所选键",#selector(stageLightOff));let clearButton=button("清空全部配色…",#selector(clearAllLightingColors));paletteEditButtons=[paintButton,offButton,clearButton]
        place(clearButton,708,98,156,30,in:colors)
        place(paintButton,8,158,192,30,in:colors);place(offButton,218,158,172,30,in:colors)
        place(button("仅导入官方灯效…",#selector(importLightingDraft)),431,158,260,30,in:colors)
        let savePalette=button("保存本机配色",#selector(saveRawLightingDraft));savePalette.toolTip="只保存与最近读回一致的原始 RGB；未写入草稿请导出 JSON。不会写入键盘。"
        place(savePalette,708,158,156,30,in:colors)
        place(label("配色全局亮度",12),8,207,105,24,in:colors)
        paletteBrightness.numberOfTickMarks=5;paletteBrightness.allowsTickMarkValuesOnly=true;paletteBrightness.target=self;paletteBrightness.action=#selector(stagePaletteBrightness);controls.append(paletteBrightness)
        place(paletteBrightness,116,204,165,25,in:colors);place(paletteBrightnessLabel,294,207,42,24,in:colors)
        paletteHelp.font = .systemFont(ofSize:12);place(paletteHelp,353,199,511,44,in:colors)
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
    var paletteEditable:Bool{profile?.lightingColorEncoding == .officialRGB && profile?.lightingMapping != nil && profile?.snapshot.colors != nil}
    func updatePaletteControls(){
        let editable = !busy && paletteEditable
        paletteEditButtons.forEach{$0.isEnabled=editable};paletteBrightness.isEnabled=editable
        let level=Int(profile?.snapshot.parameters[2] ?? 0);paletteBrightness.doubleValue=Double(level);paletteBrightnessLabel.stringValue="\(level)/4"
        if !paletteEditable{paletteHelp.stringValue="请新建逐键配色或导入官方原始配色；读回颜色仅供查看，不能反推原始 RGB。"}
        else if level==0{paletteHelp.stringValue="全局亮度为 0，配色将全部熄灭；原始 RGB 保留。此处调整直接保存到草稿。"}
        else{paletteHelp.stringValue="原始配色可编辑。全局亮度与所选键 RGB 强度分别设置；不会自动写入。"}
    }
    func requireEditablePalette()throws{
        guard paletteEditable else{throw HardwareError(message:"请先新建逐键配色或导入官方原始配色，取得 LED 映射；读回 RGB 不能直接作为原始配色编辑。")}
    }
    @objc func stagePaletteBrightness(){
        guard !busy,var draft=profile else{return}
        do{try requireEditablePalette();let level=Int(paletteBrightness.doubleValue.rounded());guard (0...4).contains(level)else{throw HardwareError(message:"亮度须为 0～4。")}
            draft.snapshot.parameters[2]=UInt8(level);profile=draft;brightness.doubleValue=Double(level);update()
            message.stringValue="配色全局亮度已保存到草稿，原始 RGB 保留；尚未写入。"
        }catch{message.stringValue=error.localizedDescription;updatePaletteControls()}
    }
    @objc func clearAllLightingColors(){
        guard !busy,let draft=profile else{return}
        do{
            try requireEditablePalette()
            let alert=NSAlert();alert.messageText="清空全部逐键配色？";alert.informativeText="全部 RGB（包含隐藏位置和官方模板颜色）设为黑色，并选择自定义模式。按键、宏、亮度和其他参数保留。只改编辑区，尚未写入；可用撤销编辑恢复最近读回。"
            alert.addButton(withTitle:"清空配色");alert.addButton(withTitle:"取消")
            guard alert.runModal() == .alertFirstButtonReturn else{return}
            profile=try WindowsProfile.clearCustomLightingDraft(draft);loadLighting();update()
            message.stringValue="全部逐键配色已清空，尚未写入。"
        }catch{message.stringValue=error.localizedDescription}
    }
    @objc func stageColor(){
        guard !busy,var draft=profile,let colors=draft.snapshot.colors else{message.stringValue="请先读取键盘。";return}
        do{
            try requireEditablePalette();let start=try readLightColor()
            draft.snapshot.colors=try CherryLighting.paint(colors,keys:keyboardLayout(),selected:lightSelection,pattern:lightPattern.indexOfSelectedItem,start:start,end:rgb(endColor.color),lightingMapping:draft.lightingMapping)
            draft.snapshot.parameters[1]=8;profile=draft;modePicker.selectItem(at:1)
            message.stringValue="已为 \(lightSelection.count) 键加入配色，并选择自定义模式。编辑仅用于预览，尚未写入键盘。"
            update();loadLightColor()
        }catch{message.stringValue=error.localizedDescription}
    }
    @objc func stageLightOff(){
        guard !busy,var draft=profile,let colors=draft.snapshot.colors else{message.stringValue="请先读取键盘。";return}
        do{try requireEditablePalette();draft.snapshot.colors=try CherryLighting.paint(colors,keys:keyboardLayout(),selected:lightSelection,pattern:0,start:LightRGB(0,0,0),end:LightRGB(0,0,0),lightingMapping:draft.lightingMapping)
            draft.snapshot.parameters[1]=8;profile=draft;modePicker.selectItem(at:1);update();loadLightColor()
            message.stringValue="已将所选 \(lightSelection.count) 键设为熄灭。编辑仅用于预览，尚未写入键盘。"
        }catch{message.stringValue=error.localizedDescription}
    }
    @objc func lightModeChanged(){updateLightingOptions()}
    func selectedLightingOptions()->CherryLighting.ModeOptions? {
        let index=modePicker.indexOfSelectedItem
        guard modes.indices.contains(index) else{return nil}
        return CherryLighting.options(for:modes[index].1)
    }
    func updateLightingOptions(){
        let options=selectedLightingOptions()
        speed.isEnabled = !busy && options?.speed==true
        lightDirection.isEnabled = !busy && options?.direction==true
        lightRainbow.isEnabled = !busy && options?.rainbow==true
        globalLightColor.isEnabled = !busy && options?.color==true
        globalLightColorButton?.isEnabled = !busy && options?.color==true
        guard let options else{lightModeHelp.stringValue="当前模式的可调选项尚未确认；保留速度、方向及颜色参数。";return}
        var unavailable:[String]=[]
        if !options.speed{unavailable.append("速度")};if !options.direction{unavailable.append("方向")}
        if !options.rainbow{unavailable.append("单色／彩虹切换")};if !options.color{unavailable.append("内置单色")}
        lightModeHelp.stringValue=unavailable.isEmpty ? "可调整速度、方向和颜色。保存到编辑区后再核对灯效计划。":"本模式不提供："+unavailable.joined(separator:"、")+"。保存时保留这些参数原值；逐键颜色请在逐键配色页编辑。"
    }
    @objc func stageLights(){
        guard !busy,var draft=profile,(0..<modes.count).contains(modePicker.indexOfSelectedItem)else{message.stringValue="请先读取键盘。";return}
        draft.snapshot.parameters[1]=modes[modePicker.indexOfSelectedItem].1
        draft.snapshot.parameters[2]=UInt8(Int(brightness.doubleValue.rounded()))
        let options=selectedLightingOptions()
        if options?.speed==true{draft.snapshot.parameters[3]=UInt8(4-Int(speed.doubleValue.rounded()))}
        if options?.direction==true,lightDirection.indexOfSelectedItem>0{draft.snapshot.parameters[4]=UInt8(lightDirection.indexOfSelectedItem-1)}
        if options?.rainbow==true,lightRainbow.indexOfSelectedItem>0{draft.snapshot.parameters[5]=UInt8(lightRainbow.indexOfSelectedItem-1)}
        profile=draft;message.stringValue="已保存此模式的可调参数，不适用的参数保留原值；尚未写入键盘。";update()
    }
    @objc func stageGlobalLightColor(){
        guard !busy,var draft=profile else{message.stringValue="请先读取键盘。";return}
        guard let options=selectedLightingOptions(),options.color else{message.stringValue="此模式不提供内置单色调整。";return}
        let value=rgb(globalLightColor.color);draft.snapshot.parameters.replaceSubrange(6..<9,with:value.bytes)
        if options.rainbow{draft.snapshot.parameters[5]=0;lightRainbow.selectItem(at:1)}
        profile=draft;message.stringValue="已把内置灯效颜色保存到编辑区，尚未写入。"
    }
}

#if CHERRY_LIGHTING_TEST
import IOKit.hid

extension HardwareWindowController {
    @objc func openLightingAcceptance(){
        guard !busy,macroRecordingSheet==nil,let owner=window else{return}
        suspendHostTextForConfiguration();busy=true;controls.forEach{$0.isEnabled=false}
        let prepared:Data?;var preparationFailure:String?
        do{
            if baselineWasRead,let baseline,let profile{
                let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
                prepared=try encoder.encode(WindowsProfile.reviewLightingDraft(profile,baseline:baseline))
            }else{prepared=nil}
        }catch{prepared=nil;preparationFailure=error.localizedDescription}
        let editorBaseline=baseline,editorDraft=profile
        let preparedReview=prepared.flatMap{try? JSONDecoder().decode(WindowsProfile.LightingDraftReview.self,from:$0)}
        let acceptance=LightingAcceptanceWindow(queue:queue,prepared:prepared);lightingAcceptance=acceptance
        if let preparationFailure{acceptance.state.stringValue="编辑区计划不能生成：\(preparationFailure)。可载入已有恢复记录。"}
        owner.beginSheet(acceptance.window!){[weak self] _ in
            guard let self else{return};self.lightingAcceptance=nil;self.busy=false
            self.controls.forEach{$0.isEnabled=true};self.baseline=nil;self.baselineWasRead=false
            self.message.stringValue="灯效验收窗口已关闭；草稿保留，请重新读取键盘后继续编辑。"
            if let receipt=acceptance.editorResult,acceptance.readback==receipt.current,
               let original=editorBaseline,let draft=editorDraft{
                do{
                    try original.validate();try receipt.current.validate();try draft.validate()
                    let accepted:Bool
                    switch receipt.kind{
                    case .write:
                        accepted=receipt.review?.original==original && receipt.review?.target.hasSameConfiguration(as:receipt.current)==true && receipt.review?.plan==preparedReview?.plan && preparedReview?.target.hasSameConfiguration(as:receipt.current)==true
                    case .restore:
                        accepted=receipt.current.hasSameConfiguration(as:original)
                    }
                    guard accepted else{throw HardwareError(message:"独立窗口结果与编辑区原计划不一致。")}
                    // Keep the official raw RGB draft; a firmware readback has
                    // already had brightness applied and must not replace it.
                    self.profile=draft;self.baseline=receipt.current;self.baselineWasRead=true
                    self.message.stringValue=receipt.kind == .write ? "灯效写入结果已接回编辑区，完整读回一致；未发送的键位、宏与文本草稿保留。外观与断电保存尚待验收。":"灯效恢复结果已接回编辑区，原始读回一致；所有未发送草稿保留。"
                    if receipt.kind == .write {
                        do{try self.rememberRawLighting(draft,current:receipt.current)}
                        catch{self.message.stringValue += "\n读回已核对，但本机原始配色资料保存失败：\(error.localizedDescription)"}
                    }
                }catch{self.message.stringValue="灯效窗口已关闭，草稿保留；\(error.localizedDescription) 请重新读取键盘。"}
            }
            self.loadLighting();self.loadSelectedAssignment();self.update()
        }
    }
}

// Compiled only into explicit research builds. Opening the sheet performs no
// device or permission access; the user must click the read button first.
final class LightingAcceptanceWindow:NSWindowController,NSWindowDelegate {
    let queue:DispatchQueue
    let directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CherryMac/LightingAcceptance/\(UUID().uuidString)")
    let state=NSTextField(wrappingLabelWithString:"尚未选择文件。不会自动连接或写入。")
    let summary=NSTextField(wrappingLabelWithString:"载入灯效写入核对文件，或之前保存的写入／恢复记录。")
    var buttons:[NSButton]=[];var running=false;var log:HardwareOperationLog?
    var review:WindowsProfile.LightingDraftReview?;var recoveryData:Data?
    struct EditorResult{
        enum Kind{case write,restore}
        let kind:Kind;let current:HardwareSnapshot;let review:WindowsProfile.LightingDraftReview?
    }
    var editorResult:EditorResult?
    var readback:HardwareSnapshot?;var writtenTarget:HardwareSnapshot?;var attempted=false
    var manager:IOHIDManager?;var registryID:UInt64?;var cycle:CalculatorPowerCycleEvidence?
    var refresh:Timer?;var focusObserver:NSObjectProtocol?;var connectionRevision=0
    var powerEvents:[[String:Any]]=[];var monitorFailure:String?
    init(queue:DispatchQueue,prepared:Data?=nil){
        self.queue=queue
        let panel=NSWindow(contentRect:NSRect(x:0,y:0,width:810,height:550),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        panel.title="CherryMac · 灯效独立验收";super.init(window:panel);panel.delegate=self
        let root=FlippedView(frame:NSRect(x:0,y:0,width:810,height:550));panel.contentView=root
        func text(_ value:String,_ y:CGFloat,_ h:CGFloat){let field=NSTextField(wrappingLabelWithString:value);field.frame=NSRect(x:22,y:y,width:766,height:h);root.addSubview(field)}
        text("研究入口 · 尚未完成真机验收。普通预览版仍不开放灯效写入。",18,35)
        text("1. 载入核对计划或恢复记录",58,25)
        summary.frame=NSRect(x:22,y:92,width:766,height:48);root.addSubview(summary)
        text("2. USB 读取与写入：关闭其他配置程序，切换有线模式。松开全部按键，写入期间保持此窗口前台。",154,45)
        text("3. 断电：成功写入后拔 USB、关键盘电源并确认；至少等待 15 秒后开电、接 USB，重新读取再核对。软件记录关电确认，不能证明电池已断电；灯光外观需要观察。",267,62)
        text("4. 每次操作自动保存备份与恢复记录。恢复重新读取并检查范围，不自动重试。",387,42)
        let titles=["载入文件…","读取 USB 配置","备份并写入","恢复原始数据","停止后续发送","已关电，开始计时","核对断电重连读回","打开本轮资料","关闭"]
        let actions:[Selector]=[#selector(load),#selector(read),#selector(write),#selector(restore),#selector(stop),#selector(powerOff),#selector(retention),#selector(showFiles),#selector(finish)]
        let frames=[NSRect(x:610,y:58,width:178,height:30),NSRect(x:22,y:210,width:165,height:32),NSRect(x:202,y:210,width:165,height:32),NSRect(x:382,y:210,width:165,height:32),NSRect(x:562,y:210,width:226,height:32),NSRect(x:22,y:338,width:232,height:32),NSRect(x:272,y:338,width:254,height:32),NSRect(x:22,y:438,width:190,height:32),NSRect(x:668,y:438,width:120,height:32)]
        for i in titles.indices{let b=NSButton(title:titles[i],target:self,action:actions[i]);b.bezelStyle = .rounded;b.frame=frames[i];root.addSubview(b);buttons.append(b)}
        let resume=NSButton(title:"载入最近恢复记录",target:self,action:#selector(loadLatestRecovery));resume.bezelStyle = .rounded;resume.frame=NSRect(x:402,y:58,width:194,height:30);root.addSubview(resume);buttons.append(resume)
        state.frame=NSRect(x:22,y:488,width:766,height:48);root.addSubview(state)
        focusObserver=NotificationCenter.default.addObserver(forName:NSWindow.didResignKeyNotification,object:panel,queue:.main){[weak self] _ in if self?.running==true{self?.log?.requestCancellation()}}
        refresh=Timer.scheduledTimer(withTimeInterval:0.5,repeats:true){[weak self] _ in self?.render()}
        if let prepared{loadData(prepared,source:"编辑区计划")};render()
    }
    required init?(coder:NSCoder){fatalError()}
    func render(){
        buttons.forEach{$0.isEnabled = !running};buttons[4].isEnabled=running
        buttons[2].isEnabled = !running && review != nil && readback != nil && !attempted
        buttons[3].isEnabled = !running && recoveryData != nil && registryID != nil && readback != nil
        buttons[5].isEnabled = !running && writtenTarget != nil && cycle?.disconnectedAt != nil && cycle?.reconnectedAt == nil
        buttons[6].isEnabled = !running && writtenTarget != nil && cycle?.hasConfirmedPowerCycle==true && registryID==cycle?.reconnectedRegistryID && readback != nil
    }
    func fail(_ error:Error){state.stringValue=error.localizedDescription}
    @objc func load(){
        guard !running else{return};let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else{return}
        resetInput();do{loadData(try Data(contentsOf:url),source:"选择的文件")}catch{fail(error);render()}
    }
    @objc func loadLatestRecovery(){
        guard !running else{return};resetInput()
        do{
            let root=directory.deletingLastPathComponent(),manager=FileManager.default
            guard manager.fileExists(atPath:root.path)else{throw HardwareError(message:"没有本机灯效恢复记录；可选择之前保存的恢复文件。")}
            let sessions=try manager.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey],options:.skipsHiddenFiles)
            var candidates:[(URL,Date)]=[]
            for session in sessions{
                let folder=try session.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]);guard folder.isDirectory==true,folder.isSymbolicLink != true else{continue}
                for url in try manager.contentsOfDirectory(at:session,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.contentModificationDateKey],options:.skipsHiddenFiles) where url.lastPathComponent.hasPrefix("record-") && url.pathExtension=="json"{
                    let values=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.contentModificationDateKey]);guard values.isRegularFile==true,values.isSymbolicLink != true else{continue}
                    guard let date=values.contentModificationDate else{throw HardwareError(message:"本机恢复记录缺少保存时间，请选择原始文件。")};candidates.append((url,date))
                }
            }
            guard let latest=candidates.sorted(by:{$0.1==$1.1 ? $0.0.path>$1.0.path:$0.1>$1.1}).first?.0 else{throw HardwareError(message:"没有本机灯效恢复记录；可选择之前保存的恢复文件。")}
            guard let size=try latest.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=3_000_000 else{throw HardwareError(message:"本机灯效恢复记录超过 3 MB，请选择原始备份。")}
            let data=try Data(contentsOf:latest),object=try JSONSerialization.jsonObject(with:data) as? [String:Any]
            guard ["CherryMacLightingRecoveryRecord","CherryMacLightingRestoreAttempt"].contains(object?["format"] as? String ?? "")else{throw HardwareError(message:"最近恢复记录身份无效，请选择原始文件。")}
            loadData(data,source:"本机最近恢复记录")
        }catch{fail(error);render()}
    }
    func resetInput(){editorResult=nil;review=nil;recoveryData=nil;writtenTarget=nil;cycle=nil;attempted=false;summary.stringValue="正在核对新计划；旧选择已清除。"}
    func loadData(_ data:Data,source:String){
        guard !running else{return};resetInput()
        do{
            guard data.count<=3_000_000 else{throw HardwareError(message:"文件超过 3 MB。")}
            let root=try JSONSerialization.jsonObject(with:data) as? [String:Any]
            if root?["format"] as? String=="CherryMacLightingDraftReview" {
                let value=try JSONDecoder().decode(WindowsProfile.LightingDraftReview.self,from:data)
                guard value.version==1,!value.hardwareReady,try value.plan.expectedReadback(from:value.original)==value.target else{throw HardwareError(message:"灯效核对目标与计划不一致。")}
                _ = try WindowsProfile.OfficialLightingPlan.CandidateAuthorization(plan:value.plan,baseline:value.original)
                if (value.target.parameters[1]==8 || value.plan.defaultColorData != nil),value.lightingMapping==nil{throw HardwareError(message:"逐键计划缺少 LED 映射，请从主编辑器重新准备计划。旧恢复记录仍可载入。")}
                _ = try value.lightingMapping?.slots(for:value.original)
                review=value;summary.stringValue="\(value.plan.defaultColorData != nil ? "默认配色 → 参数；":"")模式 \(value.target.parameters[1]) · 亮度 \(value.target.parameters[2])/4。按键与宏保持备份，尚未写入。"
            }else if root?["format"] as? String=="CherryMacLightingRecoveryRecord" {
                _ = try JSONDecoder().decode(WindowsProfile.OfficialLightingPlan.RecoveryRecord.self,from:data).assess();recoveryData=data;summary.stringValue="已载入写入恢复记录；恢复前重新读取配置。"
            }else if root?["format"] as? String=="CherryMacLightingRestoreAttempt" {
                _ = try JSONDecoder().decode(WindowsProfile.OfficialLightingPlan.RecoveryPlan.Attempt.self,from:data).assess();recoveryData=data;summary.stringValue="已载入恢复中断记录；保留原计划并核对新读回。"
            }else{throw HardwareError(message:"请选择灯效核对文件、写入记录或恢复记录。")}
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);try data.write(to:directory.appendingPathComponent("loaded-\(UUID().uuidString).json"),options:.atomic)
            state.stringValue="\(source)已核对，请点击读取 USB 配置；未连接或写入键盘。"
        }catch{review=nil;recoveryData=nil;fail(error)};render()
    }
    func startMonitor()throws {
        guard manager==nil else{return}
        let m=IOHIDManagerCreate(kCFAllocatorDefault,0)
        IOHIDManagerSetDeviceMatching(m,[kIOHIDVendorIDKey:0x046A,kIOHIDProductIDKey:0x01CE,kIOHIDTransportKey:"USB"] as CFDictionary)
        let context=Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceRemovalCallback(m,{context,_,_,device in
            guard let context else{return};let selfRef=Unmanaged<LightingAcceptanceWindow>.fromOpaque(context).takeUnretainedValue()
            guard let selectedID=selfRef.registryID,selfRef.id(device)==selectedID else{return}
            selfRef.connectionRevision += 1
            selfRef.readback=nil;selfRef.editorResult=nil;selfRef.log?.requestCancellation()
            if selfRef.writtenTarget != nil{
                selfRef.cycle = .init(originalRegistryID:selectedID)
                selfRef.cycle?.disconnected(at:ProcessInfo.processInfo.systemUptime)
            }
            selfRef.savePowerEvent("usbDisconnected");selfRef.render()
        },context)
        IOHIDManagerRegisterDeviceMatchingCallback(m,{context,_,_,device in
            guard let context else{return};let selfRef=Unmanaged<LightingAcceptanceWindow>.fromOpaque(context).takeUnretainedValue()
            if let id=selfRef.id(device),selfRef.cycle?.reconnected(at:ProcessInfo.processInfo.systemUptime,registryID:id)==true{selfRef.savePowerEvent("usbReconnected",registry:id)};selfRef.render()
        },context)
        IOHIDManagerScheduleWithRunLoop(m,CFRunLoopGetMain(),CFRunLoopMode.commonModes.rawValue)
        guard IOHIDManagerOpen(m,0)==0 else{IOHIDManagerUnscheduleFromRunLoop(m,CFRunLoopGetMain(),CFRunLoopMode.commonModes.rawValue);throw HardwareError(message:"无法监测 USB 连接，请检查研究 App 的输入监控权限。")}
        manager=m
    }
    func savePowerEvent(_ kind:String,registry:UInt64?=nil){
        powerEvents.append(["kind":kind,"at":ISO8601DateFormatter().string(from:Date()),"uptime":ProcessInfo.processInfo.systemUptime,"registryID":registry ?? registryID ?? 0])
        do{try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);try JSONSerialization.data(withJSONObject:powerEvents,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("power-events.json"),options:.atomic)}catch{monitorFailure=error.localizedDescription;fail(error)}
    }
    func id(_ device:IOHIDDevice)->UInt64?{var value:UInt64=0;return IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device),&value)==KERN_SUCCESS ? value:nil}
    func perform(_ kind:String,completed:((HardwareSnapshot)->Void)?=nil,_ body:@escaping (CherryUSB,HardwareOperationLog)throws->HardwareSnapshot?){
        guard !running else{return};editorResult=nil;let operation:HardwareOperationLog
        do{operation=try HardwareOperationLog(kind:kind,directory:directory);operation.record("scope","lighting only; keymap and macros preserved");operation.record("phase","started");try operation.requireHealthy()}catch{fail(error);return}
        let startedRevision=connectionRevision
        log=operation;running=true;render();state.stringValue="正在操作，请保持窗口前台并松开全部按键…"
        queue.async{[weak self] in
            guard let self else{return}
            var result=Result<HardwareSnapshot?,Error>{try operation.requireHealthy();let usb=try CherryUSB();usb.trace=operation.trace;operation.record("openedRegistryID",try usb.lightingRegistryID());try operation.requireHealthy();return try body(usb,operation)}
            operation.record("endedAt",ISO8601DateFormatter().string(from:Date()))
            switch result {
            case .success:
                operation.record("phase",operation.isCancelled ? "cancelled":"complete")
            case .failure(let error):
                operation.record("error",error.localizedDescription)
                operation.record("phase",operation.isCancelled ? "cancelled":"failed")
            }
            do{try operation.requireStorageHealthy()}catch{result = .failure(error)}
            let finalResult=result
            DispatchQueue.main.async{self.running=false;self.log=nil
                if case .success(let snapshot)=finalResult{
                    if self.connectionRevision==startedRevision,!operation.isCancelled{
                        if let snapshot{self.readback=snapshot;completed?(snapshot)}
                    }else{
                        self.readback=nil;self.editorResult=nil
                        self.state.stringValue="操作结束后设备已断开或收到停止请求；资料已保留，请重新读取后继续。"
                    }
                }
                else if case .failure(let error)=finalResult{self.readback=nil;self.fail(error)}
                self.render()
            }
        }
    }
    @objc func read(){
        guard !running else{return};readback=nil;registryID=nil;render()
        do{try startMonitor();let devices=IOHIDManagerCopyDevices(manager!) as? Set<IOHIDDevice> ?? [];guard devices.count==1,let device=devices.first,let found=id(device)else{throw HardwareError(message:"需连接且仅连接一把目标 USB 键盘。")};registryID=found}
        catch{
            do{let operation=try HardwareOperationLog(kind:"lighting-acceptance-read",directory:directory);operation.record("scope","read-only preparation");operation.record("error",error.localizedDescription);operation.record("endedAt",ISO8601DateFormatter().string(from:Date()));operation.record("phase","failed");try operation.requireStorageHealthy();fail(error)}
            catch{fail(error)}
            return
        }
        let selectedID=registryID!
        perform("lighting-acceptance-read"){usb,log in
            guard try usb.lightingRegistryID()==selectedID else{throw HardwareError(message:"读取会话与选定 USB 设备不同，请重新读取。")}
            let snapshot=try usb.completeSnapshot()
            guard try usb.lightingRegistryID()==selectedID else{throw HardwareError(message:"读回期间 USB 设备改变。")}
            try self.saveSnapshot(snapshot,log);try log.requireStorageHealthy();DispatchQueue.main.async{self.state.stringValue="完整配置已读取；没有写入。"};return snapshot
        }
    }
    func confirmation(_ title:String)->Bool{let alert=NSAlert();alert.messageText=title;alert.informativeText="将实际发送灯效配置。请关闭其他配置程序、松开全部按键，保持此窗口前台。自动备份与日志保存后才发送；不自动重试。";alert.addButton(withTitle:"全部已松开，继续");alert.addButton(withTitle:"取消");return alert.runModal() == .alertFirstButtonReturn}
    func saveSnapshot(_ snapshot:HardwareSnapshot,_ log:HardwareOperationLog)throws{let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];try encoder.encode(snapshot).write(to:directory.appendingPathComponent("snapshot-\(log.url.lastPathComponent)"),options:.atomic)}
    func saveVerifiedLightingFile(_ data:Data,to url:URL)throws {
        try data.write(to:url,options:.atomic)
        let handle=try FileHandle(forWritingTo:url);defer{try? handle.close()};try handle.synchronize()
        guard try Data(contentsOf:url)==data else{throw HardwareError(message:"恢复资料读回不一致，停止后续发送。")}
    }
    func backup(_ snapshot:HardwareSnapshot,_ log:HardwareOperationLog)throws{
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let url=directory.appendingPathComponent("backup-\(UUID().uuidString).json");try saveVerifiedLightingFile(encoder.encode(snapshot),to:url)
        let read=try JSONDecoder().decode(HardwareSnapshot.self,from:Data(contentsOf:url));guard read==snapshot else{throw HardwareError(message:"备份读回不一致。")}
        log.record("backup",url.path);try log.requireStorageHealthy()
    }
    func persist<T:Encodable>(_ record:T,_ log:HardwareOperationLog)throws {
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];let data=try encoder.encode(record)
        let filename="record-\(log.url.lastPathComponent)"
        try saveVerifiedLightingFile(data,to:directory.appendingPathComponent(filename))
        if log.string("recoveryRecordFile")==nil{log.record("recoveryRecordFile",filename)}
        try log.requireStorageHealthy();DispatchQueue.main.async{self.recoveryData=data}
    }
    @objc func write(){
        guard !running,!attempted,let review,let selectedID=registryID,readback != nil,confirmation("写入所选灯效计划？") else{return}
        attempted=true;cycle=nil;writtenTarget=nil
        perform("lighting-acceptance-write",completed:{[weak self] current in
            guard current.hasSameConfiguration(as:review.target) else{return}
            self?.editorResult=EditorResult(kind:.write,current:current,review:review)
        }){usb,log in
            guard try usb.lightingRegistryID()==selectedID else{throw HardwareError(message:"写入会话与此前读取设备不同，请重新读取。")}
            let result=try usb.applyLightingCandidate(review.plan,baseline:review.original,lightingMapping:review.lightingMapping,cancelled:{log.isCancelled},backup:{try self.backup($0,log)},persist:{try self.persist($0,log)},log:log)
            guard result.readbackMatches else{throw HardwareError(message:result.failure)}
            DispatchQueue.main.async{self.writtenTarget=review.target;self.state.stringValue="写入与完整读回一致。请观察灯光，再拔 USB、关电并确认。尚未验证外观与断电保留。"}
            return result.current
        }
    }
    @objc func restore(){
        guard !running,let data=recoveryData,let selectedID=registryID,readback != nil,confirmation("重新核对并恢复原始灯效数据？")else{return}
        perform("lighting-acceptance-restore",completed:{[weak self] current in
            self?.editorResult=EditorResult(kind:.restore,current:current,review:nil)
        }){usb,log in
            guard try usb.lightingRegistryID()==selectedID else{throw HardwareError(message:"恢复会话与此前读取设备不同，请重新读取。")}
            let current=try usb.completeSnapshot()
            guard try usb.lightingRegistryID()==selectedID else{throw HardwareError(message:"恢复准备期间 USB 设备改变，请重新读取。")}
            let plan=try WindowsProfile.restorePlanFromRecord(data,current:current)
            let attempt=try usb.restoreLightingCandidate(plan,cancelled:{log.isCancelled},backup:{try self.backup($0,log)},persist:{try self.persist($0,log)},log:log)
            let assessment=try attempt.assess();guard ["readbackMatched","alreadyMatched"].contains(assessment.status)else{throw HardwareError(message:attempt.failure.isEmpty ? assessment.status:attempt.failure)}
            DispatchQueue.main.async{self.writtenTarget=nil;self.cycle=nil;self.state.stringValue="恢复与原始备份读回一致。请核对键盘输出与灯光外观，再保存本轮资料。"};return attempt.current
        }
    }
    @objc func stop(){log?.requestCancellation();state.stringValue="已请求停止后续报告，不能撤回已发送的报告。"}
    @objc func powerOff(){guard !running,cycle?.confirmPowerOff(at:ProcessInfo.processInfo.systemUptime)==true else{return};savePowerEvent("userConfirmedPowerOff");state.stringValue=monitorFailure.map{"关电记录保存失败：\($0)"} ?? "已记录你的关电确认。至少等待 15 秒后开电、接 USB，并重新读取。";render()}
    @objc func retention(){
        guard !running,let target=writtenTarget,let evidence=cycle,evidence.hasConfirmedPowerCycle,let reconnectedID=evidence.reconnectedRegistryID,registryID==reconnectedID,monitorFailure==nil else{return}
        let retainedReview=review
        perform("lighting-acceptance-retention",completed:{[weak self] current in
            guard let retainedReview,current.hasSameConfiguration(as:retainedReview.target) else{return}
            self?.editorResult=EditorResult(kind:.write,current:current,review:retainedReview)
        }){usb,log in
            guard try usb.lightingRegistryID()==reconnectedID else{throw HardwareError(message:"读回会话不是本轮记录的重连设备，请重新核对。")}
            log.record("userConfirmedPowerOff",true);log.record("confirmedOffInterval",evidence.confirmedOffInterval ?? -1);log.record("originalRegistryID",evidence.originalRegistryID);log.record("reconnectedRegistryID",evidence.reconnectedRegistryID ?? 0)
            let current=try usb.completeSnapshot();guard try usb.lightingRegistryID()==reconnectedID else{throw HardwareError(message:"断电读回期间 USB 设备改变。")};try self.saveSnapshot(current,log);let matches=current.deviceInfo==target.deviceInfo && current.keymap==target.keymap && current.parameters==target.parameters && current.colors==target.colors && current.macroData==target.macroData
            log.record("readbackMatches",matches);try log.requireStorageHealthy()
            guard matches else{throw HardwareError(message:"断电重连读回与目标不同。请保存资料并核对恢复。")}
            DispatchQueue.main.async{self.state.stringValue="关电确认后的重连读回符合目标。请观察灯光，之后恢复原始数据。"};return current
        }
    }
    @objc func showFiles(){do{try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);NSWorkspace.shared.open(directory)}catch{fail(error)}}
    @objc func finish(){guard !running else{return};refresh?.invalidate();refresh=nil;if let observer=focusObserver{NotificationCenter.default.removeObserver(observer);focusObserver=nil};if let manager{IOHIDManagerRegisterDeviceRemovalCallback(manager,nil,nil);IOHIDManagerRegisterDeviceMatchingCallback(manager,nil,nil);IOHIDManagerUnscheduleFromRunLoop(manager,CFRunLoopGetMain(),CFRunLoopMode.commonModes.rawValue);IOHIDManagerClose(manager,0);self.manager=nil};window?.sheetParent?.endSheet(window!)}
    func windowShouldClose(_ sender:NSWindow)->Bool{finish();return false}
}
#endif
