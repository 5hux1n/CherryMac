// Local exports do not acquire/release configuration interfaces. Configuration
// callbacks must still wait for host text shutdown before any device access.
export async function runPageOperation(body,{localOnly=false,stopObservation=()=>{},invalidateText=()=>{},suspendHostText=async()=>{}}={}){
  if(!localOnly){stopObservation();invalidateText();await suspendHostText();}
  return body();
}
