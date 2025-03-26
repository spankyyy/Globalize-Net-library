# Globalize



> ## Documentation
## Serverside

`Globalize.Send(string NetworkID, table Data, table or player or nil Recipients) -> nil`
- Sends `Data` to the specified `Recipients` or `nil` if you want to broadcast the message

`Globalize.Subscribe(string NetworkID, function Callback, number seconds RateLimit) -> nil`
- Adds a `Callback` to the specificed `NetworkID`  
- The rate limiter that will trigger if a message is received before `RateLimit` seconds since the last message

`Globalize.Unsubscribe(string NetworkID) -> nil`
- Removes the callback from the specified `NetworkID`

`Globalize.SetGlobal(string VariableID, ...) -> ...`
- Sets and networks any variables that can be accessed with `Globalize.GetGlobal(string VariableID)`

`Globalize.GetGlobal(string VariableID) -> ...`
- Gets the global variables

## Clientside

`Globalize.Send(string NetworkID, table Data) -> nil`
- Sends `Data` to the server

`Globalize.Subscribe(string NetworkID, function Callback) -> nil`
- Adds a `Callback` to the specificed `NetworkID`

`Globalize.Unsubscribe(NetworkID) -> nil`
- Removes the callback from the specified NetworkID

`Globalize.GetGlobal(string VariableID) -> ...`
- Gets the global variables
