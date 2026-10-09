import {validateExtendedHardwareBackup,extendedBackupCoverage,extendedBackupBoundaryDescription} from './extended-hardware-backup.js?v=0.6.0';
import {saveExtendedHardwareBackup,loadExtendedHardwareBackup,listExtendedHardwareBackupIDs} from './extended-hardware-backup-store.js?v=0.6.0';
import {download} from './storage.js?v=0.6.0';
import {listExtendedCaptureJournalIDs,loadExtendedCaptureJournal,inspectExtendedCaptureRecords} from './extended-capture-journal.js?v=0.6.0';

// Captured and imported records never enter the editor or a write sender.
export function installExtendedBackupEditor(operation,{capture=null}={}){
  const $=id=>document.getElementById(id);let selected=null,activeCapture=null,lastCaptureID=null;
  const render=busy=>{
    for(const id of ['extended-inspect','extended-file','extended-list','extended-saved','extended-load','extended-log-inspect','extended-log-file','extended-log-list','extended-log-saved','extended-log-load'])$(id).disabled=busy;
    $('extended-capture').disabled=busy||typeof capture!=='function';
    $('extended-cancel').hidden=!activeCapture;$('extended-cancel').disabled=!activeCapture||activeCapture.signal.aborted;
    $('extended-log-export').disabled=busy||!lastCaptureID;
    $('extended-save').disabled=busy||!selected;$('extended-export').disabled=busy||!selected;
  };
  const show=value=>{
    validateExtendedHardwareBackup(value);selected=structuredClone(value);
    const names={parameters:'参数',keymap:'键位',colors:'颜色',macroData:'宏'};
    $('extended-summary').textContent=extendedBackupCoverage(value).map(row=>`${names[row.region]}：${row.storedBytes}/${row.regionBytes} 字节，未捕获偏移 ${row.missingOffsets.join('、')}`).join('；')+'。'+extendedBackupBoundaryDescription(value)+'记录不进入编辑区或完整恢复／配对流程。';
  };
  const clear=()=>{selected=null;$('extended-summary').textContent='正在检查新记录；此前选择已清除。';};
  $('extended-cancel').onclick=()=>{activeCapture?.abort();$('extended-cancel').disabled=true;};
  $('extended-capture').onclick=()=>operation(async()=>{
    if(typeof capture!=='function')throw new Error('此版本尚未提供实际扩展读取。');
    clear();const controller=new AbortController();activeCapture=controller;lastCaptureID=crypto.randomUUID();render(true);
    $('extended-log-summary').textContent=`捕获编号：${lastCaptureID}；准备读取。`;
    try{
      const result=await capture({id:lastCaptureID,cancelled:()=>controller.signal.aborted,progress:count=>{
        $('extended-summary').textContent=`只读捕获进度：${count}/160。取消会停止后续读取，并保留已保存记录。`;
      }});
      show(result.snapshot);$('extended-summary').textContent+=` 已保存并从本机库重新核对：${result.backupReference}。建议下载备份及日志；不代表完整恢复或断电验收通过。`;
      $('extended-log-summary').textContent=`捕获编号：${lastCaptureID}；两遍 ${result.completedReads} 条读取一致，备份编号：${result.backupReference}。`;
    }catch(error){
      const known=error.backupReference?` 已返回备份编号：${error.backupReference}，请通过本机库查看。`:'';
      $('extended-summary').textContent='捕获未完成：'+error.message+known+' 原编辑区保留；可以下载已保存的捕获日志。';
      $('extended-log-summary').textContent=`捕获编号：${lastCaptureID}；未完成：${error.message}`;throw error;
    }finally{activeCapture=null;render(true);}
  });
  $('extended-log-export').onclick=()=>operation(async()=>{
    if(!lastCaptureID)throw new Error('尚无本轮捕获编号。');
    const records=await loadExtendedCaptureJournal(lastCaptureID);
    if(!records.length)throw new Error('没有已确认保存的事件；可能在首次读取之前就已停止。');
    const summary=inspectExtendedCaptureRecords(records);
    download(summary.records,`CherryMac-extended-capture-${lastCaptureID}.json`);
  },{localOnly:true});
  $('extended-inspect').onclick=()=>$('extended-file').click();
  $('extended-file').onchange=()=>{
    const file=$('extended-file').files[0];if(!file)return;clear();
    return operation(async()=>{if(file.size>128_000)throw new Error('扩展备份超过 128 KB。');show(JSON.parse(await file.text()));},{localOnly:true});
  };
  $('extended-save').onclick=()=>operation(async()=>{
    if(!selected)throw new Error('请先检查扩展备份文件。');const id=await saveExtendedHardwareBackup(selected);
    $('extended-summary').textContent+=` 已保存到当前网站的本机库：${id}。建议同时下载副本。`;
  },{localOnly:true});
  $('extended-export').onclick=()=>operation(()=>{if(!selected)throw new Error('请先检查扩展备份文件。');download(selected,'CherryMac-extended-hardware.json');},{localOnly:true});
  $('extended-list').onclick=()=>operation(async()=>{
    $('extended-saved').replaceChildren();for(const id of await listExtendedHardwareBackupIDs())$('extended-saved').add(new Option(id,id));
    if(!$('extended-saved').options.length)$('extended-summary').textContent='本网站尚无已保存的扩展备份；可先选择已有原始文件。';
  },{localOnly:true});
  $('extended-load').onclick=()=>{const id=$('extended-saved').value;clear();return operation(async()=>{if(!id)throw new Error('请先查看本机库并选择记录。');show(await loadExtendedHardwareBackup(id));},{localOnly:true});};
  $('extended-log-list').onclick=()=>operation(async()=>{
    $('extended-log-saved').replaceChildren();for(const id of await listExtendedCaptureJournalIDs())$('extended-log-saved').add(new Option(id,id));
    if(!$('extended-log-saved').options.length)$('extended-log-summary').textContent='本网站没有已保存的捕获日志。';
  },{localOnly:true});
  $('extended-log-load').onclick=()=>operation(async()=>{
    const id=$('extended-log-saved').value;if(!id)throw new Error('请先查看捕获记录并选择编号。');
    const summary=inspectExtendedCaptureRecords(await loadExtendedCaptureJournal(id));lastCaptureID=id;
    $('extended-log-summary').textContent=`日志编号：${id}；已接受读取 ${summary.acceptedReads}/160；最后阶段：${summary.lastPhase}；备份编号：${summary.backupReference??'尚无'}。${summary.detail} 可下载本记录；历史记录不证明当前状态。`;
  },{localOnly:true});
  $('extended-log-inspect').onclick=()=>$('extended-log-file').click();
  $('extended-log-file').onchange=()=>{
    const file=$('extended-log-file').files[0];if(!file)return;
    $('extended-log-summary').textContent='正在检查新日志；先前摘要已清除。';
    return operation(async()=>{
      if(file.size>2_000_000)throw new Error('扩展捕获日志超过 2 MB。');
      const summary=inspectExtendedCaptureRecords(JSON.parse(await file.text()));
      const phases={started:'开始',readPrepared:'待读取回复',readAccepted:'已接受读取',saving:'保存中',saved:'已保存，待核对',complete:'记录显示流程结束',failed:'失败',cancelled:'已取消'};
      $('extended-log-summary').textContent=`日志编号：${summary.id}；已接受读取：${summary.acceptedReads}/160；最后阶段：${phases[summary.lastPhase]??summary.lastPhase}；备份编号：${summary.backupReference??'尚无'}。${summary.detail} 这里只检查历史文件，不连接键盘；记录结束不等于当前配置核对、完整恢复或断电验收。`;
    },{localOnly:true});
  };
  render(false);return {render};
}
