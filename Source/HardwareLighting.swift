import AppKit

extension HardwareWindowController {
    func buildLighting(_ pane:NSView){
        place(label("模式"),18,15,48,23,in:pane)
        modePicker.addItems(withTitles:modes.map{$0.0});controls.append(modePicker);place(modePicker,66,11,238,28,in:pane)
        place(label("亮度"),320,15,42,23,in:pane);place(brightness,366,11,133,28,in:pane)
        place(label("慢 ← 速度 → 快",11),515,15,99,23,in:pane);place(speed,615,11,115,28,in:pane)
        for slider in [brightness,speed]{slider.numberOfTickMarks=5;slider.allowsTickMarkValuesOnly=true;controls.append(slider)}
        place(label("方向"),746,15,42,23,in:pane)
        lightDirection.addItems(withTitles:["保留方向","正向","反向"]);controls.append(lightDirection);place(lightDirection,793,11,143,28,in:pane)
        controls.append(lightMultiple);place(lightMultiple,18,53,76,25,in:pane)
        lightRegion.addItems(withTitles:CherryLighting.regions);controls.append(lightRegion);place(lightRegion,101,51,135,28,in:pane)
        place(button("选择",#selector(selectLightRegion)),244,51,70,28,in:pane);place(lightCount,329,56,116,22,in:pane)
        place(label("颜色"),457,56,37,23,in:pane);place(color,497,49,55,31,in:pane)
        color.target=self;color.action=#selector(lightColorChanged);controls.append(color)
        for index in 0..<3 {
            place(label(["R","G","B"][index]),570+CGFloat(index)*121,56,20,23,in:pane)
            let field=lightRGB[index];field.tag=101+index;field.delegate=self;controls.append(field);place(field,593+CGFloat(index)*121,52,80,25,in:pane)
        }
        place(label("HEX"),18,97,36,23,in:pane);lightHex.tag=104;lightHex.delegate=self;controls.append(lightHex);place(lightHex,59,93,103,25,in:pane)
        place(label("颜色强度",12),177,97,63,23,in:pane);lightStrength.target=self;lightStrength.action=#selector(lightStrengthChanged);controls.append(lightStrength);place(lightStrength,242,93,117,25,in:pane)
        place(lightStrengthLabel,369,97,48,23,in:pane)
        place(label("渐变终点",12),432,97,65,23,in:pane);endColor.color = .systemBlue;controls.append(endColor);place(endColor,497,91,55,31,in:pane)
        lightPattern.addItems(withTitles:CherryLighting.patterns);controls.append(lightPattern);place(lightPattern,570,91,177,28,in:pane)
        place(button("应用配色到所选键",#selector(stageColor)),762,91,174,28,in:pane)
        place(button("将颜色用于内置灯效",#selector(stageGlobalLightColor)),18,135,220,28,in:pane)
        lightRainbow.addItems(withTitles:["保留颜色选项","单色","彩虹"]);controls.append(lightRainbow);place(lightRainbow,250,135,149,28,in:pane)
        place(button("加入灯效配置",#selector(stageLights)),416,135,162,28,in:pane)
        place(button("熄灭所选键",#selector(stageLightOff)),602,135,134,28,in:pane)
        place(label("⌘点击可多选。\n逐键配色为静态。",11),750,133,186,40,in:pane)
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
        guard let key=keyboardLayout().first(where:{$0.id==selected}),let slot=CherryMatrix.slot(key),let colors=profile?.snapshot.colors else{return}
        setLightColor(LightRGB(colors[slot*3],colors[slot*3+1],colors[slot*3+2]))
    }
    func controlTextDidChange(_ notification:Notification){
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
            draft.snapshot.colors=try CherryLighting.paint(colors,keys:keyboardLayout(),selected:lightSelection,pattern:lightPattern.indexOfSelectedItem,start:start,end:rgb(endColor.color))
            draft.snapshot.parameters[1]=8;profile=draft;modePicker.selectItem(at:1)
            message.stringValue="已为 \(lightSelection.count) 键加入配色，并选择自定义模式。点击「写入灯效」应用到键盘。"
            update();loadLightColor()
        }catch{message.stringValue=error.localizedDescription}
    }
    @objc func stageLightOff(){
        guard !busy,var draft=profile,let colors=draft.snapshot.colors else{message.stringValue="请先读取键盘。";return}
        do{draft.snapshot.colors=try CherryLighting.paint(colors,keys:keyboardLayout(),selected:lightSelection,pattern:0,start:LightRGB(0,0,0),end:LightRGB(0,0,0))
            draft.snapshot.parameters[1]=8;profile=draft;modePicker.selectItem(at:1);update();loadLightColor()
            message.stringValue="已将所选 \(lightSelection.count) 键设为熄灭。点击「写入灯效」应用到键盘。"
        }catch{message.stringValue=error.localizedDescription}
    }
    @objc func stageLights(){
        guard !busy,var draft=profile,(0..<modes.count).contains(modePicker.indexOfSelectedItem)else{message.stringValue="请先读取键盘。";return}
        draft.snapshot.parameters[1]=modes[modePicker.indexOfSelectedItem].1
        draft.snapshot.parameters[2]=UInt8(Int(brightness.doubleValue.rounded()))
        draft.snapshot.parameters[3]=UInt8(4-Int(speed.doubleValue.rounded()))
        if lightDirection.indexOfSelectedItem>0{draft.snapshot.parameters[4]=UInt8(lightDirection.indexOfSelectedItem-1)}
        if lightRainbow.indexOfSelectedItem>0{draft.snapshot.parameters[5]=UInt8(lightRainbow.indexOfSelectedItem-1)}
        profile=draft;message.stringValue="已加入模式、亮度和速度设置。点击「写入灯效」应用到键盘。";update()
    }
    @objc func stageGlobalLightColor(){
        guard !busy,var draft=profile else{message.stringValue="请先读取键盘。";return}
        do{let value=try readLightColor();draft.snapshot.parameters.replaceSubrange(6..<9,with:value.bytes);draft.snapshot.parameters[5]=0
            profile=draft;lightRainbow.selectItem(at:1);setLightColor(value);message.stringValue="已设置内置灯效的单色。选择模式后点击「加入灯效配置」，再写入。"
        }catch{message.stringValue=error.localizedDescription}
    }
}
