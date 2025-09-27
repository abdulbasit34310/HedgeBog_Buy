// Requires `#include <Trade/Trade.mqh>#include <Trade/Trade.mqh>
CTrade trade;

void OnStart()
{
    string symbol = Symbol();
    double volume = 0.1;
    long   magic  = 54321;
    double current_ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
    double entry_price = current_ask - SymbolInfoDouble(symbol, SYMBOL_POINT) * 100; // 10 points below Ask

    Print("Attempting to place BUY LIMIT pending order for ", volume, " lots on ", symbol, " at ", entry_price);

    if(trade.BuyLimit(volume, entry_price, symbol, 0, 0, 0, magic))
    {
        Print("Buy Limit order placed successfully.");
        long order_ticket = trade.ResultOrder();
        Print("Pending Order Ticket: ", order_ticket);
        Print("Order is pending. Monitor OnTradeTransaction for state change to FILLED.");
        Print("Once FILLED, look for a DEAL_TYPE_BUY with ORDER=", order_ticket, " and a Long Position on ", symbol);

    }
    else
    {
        Print("Buy Limit order failed. Error: ", trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(), ")");
    }
}

ulong positionID = 12345; // Your position ticket number here

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_POSITION_DELETE)
     {
      // Get the ticket of the position that was changed from the transaction
      ulong changedPositionID = trans.position;

      // Check if the changed position is the one we are monitoring
      if(changedPositionID == positionID)
        {
         // Create a CPositionInfo object to get the current details
         CPositionInfo pos;
         if(pos.SelectByTicket(changedPositionID))
           {
            // If the volume is zero, the position is fully closed
            if(pos.Volume() == 0)
              {
               Print("Position Completely Closed. Ticket: ", positionID);
               // You can add any other cleanup logic here (e.g., reset flags, log final profit)
              }
            else
              {
               // Optional: Print a message for a partial close
               Print("Position Partially Closed. Ticket: ", positionID, ", New Volume: ", pos.Volume());
              }
           }
         else
           {
            // If SelectByTicket fails, the position likely no longer exists (is closed)
            // This is a very strong indicator that it was closed.
            Print("Position Completely Closed (Unable to select, it's gone). Ticket: ", positionID);
           }
        }
     }
  }