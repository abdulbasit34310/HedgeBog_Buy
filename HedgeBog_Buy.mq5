#property copyright "Abdul Basit"
#property link "https://www.mql5.com"
#property version "1.00"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;
CPositionInfo position;

// Input parameters
input double HedgePrice = 3335.0; // The price level to open/close the hedge
input double Lots = 1;            // Volume in lots for the trade

// Global variables
bool hasOpenPosition = false;
bool hasPendingOrder = false;
string currentSymbol = Symbol();

int OnInit()
{
   PrintFormat("Hedge Bot EA initialized:");
   return (INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Print("Hedge Bot EA deinitialized. Reason: ", reason);
}

void OnTick()
{
   double bidPrice = SymbolInfoDouble(currentSymbol, SYMBOL_BID);
   double askPrice = SymbolInfoDouble(currentSymbol, SYMBOL_ASK);

   // Check if we have an active position
   Check_Open_Position();

   // Main trading logic
   if (!hasOpenPosition && !hasPendingOrder && bidPrice <= HedgePrice)
   {
     Buy_Stop();
   }
   else if (!hasOpenPosition && !hasPendingOrder && bidPrice >= HedgePrice)
   {
       Market_Buy(bidPrice);
   }
}

void Check_Open_Position()
{
   hasOpenPosition = false;
   // Check all open positions
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (position.SelectByIndex(i))
      {
         if (position.Symbol() == currentSymbol && position.PositionType() == POSITION_TYPE_BUY)
         {
            hasOpenPosition = true;
            break;
         }
      }
   }
}

void Market_Buy(double currentPrice)
{
   double point = SymbolInfoDouble(currentSymbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(currentSymbol, SYMBOL_DIGITS);

   // Calculate SL: HedgePrice + 1 pip (above entry for Buy orders)
   double stopLoss = NormalizeDouble(HedgePrice + point, digits);

   // Place immediate Buy order at current market price WITH SL
   if (trade.Buy(Lots, currentSymbol, 0, stopLoss, 0, "Market_Buy"))
   {
      hasPendingOrder = false;
      PrintFormat("Market_Buy order placed at market price with SL %.5f, Deal: %d", stopLoss);
   }
   else
   {
      PrintFormat("Failed Market_Buy. Error: %d", GetLastError());
   }
}

void Buy_Stop()
{
   // Place Buy stop order WITH stop loss
   if (trade.BuyStop(Lots, HedgePrice, currentSymbol, 0, 0, ORDER_TIME_GTC, 0, "Buy_Stop"))
   {
      hasPendingOrder = true;
      PrintFormat("Buy_Stop at %.5f",
                  HedgePrice);
   }
   else
   {
      PrintFormat("Failed Buy_Stop. Error: %d", GetLastError());
   }
}