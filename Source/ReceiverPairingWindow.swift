import AppKit

// Product discovery/selection sheet. Device access begins only on Refresh.
// No pairing transport is constructed and no configuration report is sent.
@MainActor final class ReceiverPairingWindow:NSWindowController,NSWindowDelegate {
    private let devices=ReceiverPairingDevices()
    private let keyboard=NSPopUpButton(),receiver=NSPopUpButton()
    private let status=NSTextField(wrappingLabelWithString:"先连接 USB 有线键盘与接收器，再点击查看设备。")
    private let review=NSButton(title:"核对所选连接",target:nil,action:nil)
    private var candidates:[ReceiverPairingCandidate]=[]
    private var selection:ReceiverPairingSelection?
    private var active=false,finished=false
    private let completion:()->Void
    init(completion:@escaping()->Void){
        self.completion=completion
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:740,height:394),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        super.init(window:window);window.title="接收器连接准备";window.delegate=self
        let view=HardwareCanvas(frame:NSRect(x:0,y:0,width:740,height:394));window.contentView=view
        func place(_ child:NSView,_ x:CGFloat,_ y:CGFloat,_ width:CGFloat,_ height:CGFloat){child.frame=NSRect(x:x,y:y,width:width,height:height);view.addSubview(child)}
        place(NSTextField(wrappingLabelWithString:"选择要配对的键盘和 2.4G 接收器。此页面只发现设备与核对连接，尚未开放配对发送。"),24,20,690,48)
        for (name,picker,y) in [("USB 有线键盘",keyboard,CGFloat(90)),("2.4G 接收器",receiver,CGFloat(146))]{
            place(NSTextField(labelWithString:name),24,y,145,28);place(picker,176,y,538,30)
            picker.target=self;picker.action=#selector(changed);picker.setAccessibilityLabel(name)
        }
        place(status,24,202,690,66)
        place(NSButton(title:"查看／刷新设备",target:self,action:#selector(refresh)),24,288,174,32)
        review.target=self;review.action=#selector(check);place(review,212,288,174,32)
        place(NSButton(title:"停止查看",target:self,action:#selector(stop)),400,288,140,32)
        place(NSButton(title:"完成",target:self,action:#selector(finish)),574,340,140,32)
        devices.onChange={[weak self] candidates in self?.update(candidates)}
        devices.onError={[weak self] error in self?.active=false;self?.status.stringValue=error.localizedDescription;self?.selection=nil}
        update([])
    }
    required init?(coder:NSCoder){fatalError()}
    private func token(_ picker:NSPopUpButton)->String?{picker.selectedItem?.representedObject as? String}
    private func update(_ rows:[ReceiverPairingCandidate]){
        candidates=rows
        if let selection,!rows.contains(selection.keyboard) || !rows.contains(selection.receiver){
            self.selection=nil;status.stringValue="所选设备已断开或改变，请重新选择并核对。"
        }
        for (role,picker) in [(ReceiverPairingRole.keyboard,keyboard),(.receiver,receiver)]{
            let previous=token(picker),eligible=rows.filter{$0.role==role}
            picker.removeAllItems();picker.addItem(withTitle:eligible.isEmpty ? "未发现可用接口":"请选择设备")
            for candidate in eligible{
                picker.addItem(withTitle:"\(String(format:"%04X:%04X",candidate.vendorID,candidate.productID)) · 接口 \(candidate.token.prefix(12))")
                picker.lastItem?.representedObject=candidate.token
            }
            if let previous,let index=picker.itemArray.firstIndex(where:{$0.representedObject as? String==previous}){picker.selectItem(at:index)}
            else if eligible.count==1{picker.selectItem(at:1)}
            picker.isEnabled=active && !eligible.isEmpty
        }
        review.isEnabled=active && token(keyboard) != nil && token(receiver) != nil
    }
    @objc private func refresh(){
        selection=nil;active=true;status.stringValue="正在发现设备；系统可能要求输入监控权限。"
        do{try devices.start();status.stringValue="列表已刷新。多个接口时请明确选择；断开与重连会更新列表。"}
        catch{active=false;devices.stop();status.stringValue=error.localizedDescription}
    }
    @objc private func changed(){selection=nil;status.stringValue="选择已修改，请重新核对连接。";review.isEnabled=active && token(keyboard) != nil && token(receiver) != nil}
    @objc private func check(){
        guard active,let keyboardToken=token(keyboard),let receiverToken=token(receiver) else{return}
        do{
            devices.refresh()
            // Refresh must not silently substitute a newly discovered device.
            let resolved=try devices.resolve(keyboardToken:keyboardToken,receiverToken:receiverToken)
            try resolved.selection.validate();selection=resolved.selection
            status.stringValue="所选连接已核对。尚未发送配对命令；后续配对前仍需完整备份与协议确认。"
        }catch{selection=nil;status.stringValue=error.localizedDescription}
    }
    @objc private func stop(){active=false;selection=nil;devices.stop();status.stringValue="已停止查看，所选连接已清除。"}
    @objc func finish(){
        guard !finished else{return};finished=true;stop()
        if let window{window.sheetParent?.endSheet(window);window.orderOut(nil)};completion()
    }
    func windowShouldClose(_ sender:NSWindow)->Bool{finish();return false}
}
