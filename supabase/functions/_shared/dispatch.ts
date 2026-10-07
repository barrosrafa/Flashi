import { capturePostHogEvent } from './observability.ts';
export function dispatchEdge(functionName:string,body:Record<string,unknown>,authorization:string,requestId:string,workerSecret?:string) {
  const task=(async()=>{
    try {
      const response=await fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/${functionName}`,{method:'POST',headers:{Authorization:authorization,'Content-Type':'application/json','x-request-id':requestId,...(workerSecret?{'x-worker-secret':workerSecret}:{})},body:JSON.stringify(body),signal:AbortSignal.timeout(240_000)});
      await capturePostHogEvent({distinctId:requestId,event:response.ok?'job_started':'job_failed',properties:{function_name:functionName,request_id:requestId,status:response.status}});
    } catch { await capturePostHogEvent({distinctId:requestId,event:'job_failed',properties:{function_name:functionName,request_id:requestId,error_code:'WORKER_DISPATCH_FAILED'}}); }
  })();
  const runtime=(globalThis as any).EdgeRuntime;
  if(runtime?.waitUntil)runtime.waitUntil(task);
  return task;
}
