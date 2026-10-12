   echo "=== agenttemplate ==="; kubectl -n kagent get agenttemplate
   echo "=== agenttemplate status ==="; kubectl -n kagent get agenttemplate k8s-expert -o jsonpath='{.status}'; echo
   echo "=== remotemcpserver ==="; kubectl -n kagent get remotemcpserver
   echo "=== harness ==="; kubectl -n kagent get harness
   echo "=== kagent pods ==="; kubectl -n kagent get pods
