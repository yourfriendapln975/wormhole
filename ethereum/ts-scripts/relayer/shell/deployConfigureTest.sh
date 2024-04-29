npx tsx ./ts-scripts/relayer/config/checkNetworks.ts \
  && npx tsx ./ts-scripts/relayer/create2Factory/deployCreate2Factory.ts \
  && npx tsx ./ts-scripts/relayer/deliveryProvider/deployDeliveryProvider.ts \
  && npx tsx ./ts-scripts/relayer/wormholeRelayer/deployWormholeRelayer.ts \
  && npx tsx ./ts-scripts/relayer/deliveryProvider/initializeDeliveryProvider.ts \
  && npx tsx ./ts-scripts/relayer/wormholeRelayer/registerChainsWormholeRelayerSelfSign.ts \
  && npx tsx ./ts-scripts/relayer/mockIntegration/deployMockIntegration.ts \
  && npx tsx ./ts-scripts/relayer/config/syncContractsJson.ts 
  # && npx tsx ./ts-scripts/relayer/mockIntegration/messageTest.ts 

 # put this as 2nd script if not deployed aleady