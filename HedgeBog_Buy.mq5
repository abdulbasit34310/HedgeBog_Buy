#property copyright "Abdul Basit"
#property link "https://www.mql5.com"
#property version "1.01"
#property strict
#include <Trade\Trade.mqh>

CTrade trade;
CPositionInfo position;
COrderInfo order;

// Original variables
ulong buyStopTicket = 0; // Track our Buy Stop order ticket
bool hasOpenBuyPosition = false;
bool hasPendingOrder = false;
string currentSymbol = Symbol();
datetime pause_until = 0;
datetime last_print_time = 0;

ulong positionID = 0; // Deal ticket of our bot's position
double entryPrice = 0.0;     // Entry price of our bot's position
bool slTpAlreadySet = false; // Flag to ensure SL/TP is set only once

input double HedgePrice = 3310.0;
input double Lots = 0.1;
input double afterSLDelay = 11;
input double checkPipsMoved = 100;
input double closingPointPips = 11;

int OnInit()
{
   PrintFormat("Hedge Bot EA initialized.");
   return (INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Print("Hedge Bot EA deinitialized. Reason: ", reason);
}

void OnTick()
{
   if (IsSkippingTicks())
   {
      if (TimeCurrent() != last_print_time)
      {
         last_print_time = TimeCurrent();
         PrintFormat("Ticking stopped... %d sec left",
                     (int)(pause_until - TimeCurrent()));
      }
      return;
   }

   double bidPrice = SymbolInfoDouble(currentSymbol, SYMBOL_BID);

   Check_Open_Position();

   if (hasOpenBuyPosition && positionID > 0 && !slTpAlreadySet)
   {
      SL_TP_Adding();
   }

   if (!hasOpenBuyPosition && !hasPendingOrder && bidPrice >= HedgePrice)
   {
      Market_Buy();
   }
   else if (!hasOpenBuyPosition && !hasPendingOrder && bidPrice <= HedgePrice)
   {
      Buy_Stop();
   }
}

void Check_Open_Position()
{
   hasOpenBuyPosition = false;

   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (position.SelectByIndex(i))
      {
         if (position.Symbol() == currentSymbol && position.PositionType() == POSITION_TYPE_BUY)
         {
            hasOpenBuyPosition = true;
            break;
         }
      }
   }

   // NEW: If no buy position found, reset our tracking
   if (!hasOpenBuyPosition && positionID > 0)
   {
      PrintFormat("📝 No buy position found, clearing tracking for deal %I64u", positionID);
      positionID = 0;
      entryPrice = 0.0;
      slTpAlreadySet = false;
   }
}

void Market_Buy()
{
   if (trade.Buy(Lots, currentSymbol, 0, 0, 0, "Market_Buy"))
   {
      hasPendingOrder = false;
      ulong orderTicket = trade.ResultOrder(); // Get order ticket

      if (HistoryOrderSelect(orderTicket))
         positionID = (ulong)HistoryOrderGetInteger(orderTicket, ORDER_POSITION_ID);

      entryPrice = trade.ResultPrice();
      slTpAlreadySet = false;

      PrintFormat("Market_Buy placed at %.5f. Position ticket: %I64u", entryPrice, positionID);
   }
   else
   {
      PrintFormat("Failed Market_Buy. Error: %d", GetLastError());
   }
}

void Buy_Stop()
{
   if (trade.BuyStop(Lots, HedgePrice, currentSymbol, 0, 0, ORDER_TIME_GTC, 0, "Buy_Stop"))
   {
      buyStopTicket = trade.ResultOrder(); // Store ticket
      hasPendingOrder = true;
      PrintFormat("Buy_Stop placed at %.5f. Order Ticket: %I64u", HedgePrice, buyStopTicket);
   }
   else
   {
      PrintFormat("Failed Buy_Stop. Error: %d", GetLastError());
   }
}

void SkipTicksFor(int seconds)
{
   pause_until = TimeCurrent() + seconds;
   PrintFormat("⏸ Skipping ticks for %d seconds starting at %s, resuming at %s",
               seconds,
               TimeToString(TimeCurrent(), TIME_SECONDS),
               TimeToString(pause_until, TIME_SECONDS));
}

bool IsSkippingTicks()
{
   return (TimeCurrent() < pause_until);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   ulong order_ticket = trans.order;
   ulong posID = trans.position; // ✅ Position ID instead of deal_ticket

   // 1️⃣ Buy Stop executed into a new position
   if (trans.type == TRADE_TRANSACTION_DEAL_ADD && order_ticket == buyStopTicket)
   {
      PrintFormat("Buy Stop (Order Ticket %I64u) executed into Position %I64u.",
                  buyStopTicket, posID);

      // Track this position since it came from our Buy Stop
      positionID = posID; // ✅ now tracking position ID instead of deal
      if (PositionSelectByTicket(posID))
      {
         entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         slTpAlreadySet = false; // Reset flag for new position
         PrintFormat("📊 Tracking Buy Stop position: Position=%I64u, Entry=%.5f",
                     posID, entryPrice);
      }

      buyStopTicket = 0;
      hasPendingOrder = false;
   }

   // 2️⃣ Buy Stop deleted/canceled/expired
   if (trans.type == TRADE_TRANSACTION_ORDER_DELETE && order_ticket == buyStopTicket)
   {
      PrintFormat("⚠ Buy Stop (Order Ticket %I64u) canceled/expired. Clearing tracking.", buyStopTicket);
      buyStopTicket = 0;
      hasPendingOrder = false;
   }

   // 3️⃣ Confirmation of Buy Stop order placement
   if (trans.type == TRADE_TRANSACTION_ORDER_ADD && request.type == ORDER_TYPE_BUY_STOP)
   {
      PrintFormat("Buy Stop order confirmed by server. Ticket: %I64u", order_ticket);
   }

   // 4️⃣ Detect when our tracked position is closed (TP/SL hit or manual close)
   if (positionID > 0) // posID we are tracking
   {
      if (!PositionSelectByTicket(positionID)) // ✅ position no longer exists
      {
         PrintFormat("🔴 Our tracked position %I64u has been closed", positionID);

         // Reset tracking
         positionID = 0;
         entryPrice = 0.0;
         slTpAlreadySet = false;

         // Apply delay
         SkipTicksFor((int)afterSLDelay);
      }
   }
}

void SL_TP_Adding()
{
   if (slTpAlreadySet || entryPrice == 0.0 || positionID == 0)
      return; // Already set or nothing to track


   double bidPrice = SymbolInfoDouble(currentSymbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(currentSymbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(currentSymbol, SYMBOL_POINT);

   // Pip value logic
   double pipValue;
   if (digits == 5 || digits == 3)
      pipValue = 10 * point;
   else
      pipValue = point;

   // Check if price has moved 50 pips above OR below entryPrice
   double priceMovement = MathAbs(bidPrice - entryPrice);
   double fiftyPips = checkPipsMoved * pipValue;

   if (priceMovement < fiftyPips)
   {
      return; // Price hasn't moved enough yet
   }

   PrintFormat("📊 Price moved %.1f pips from entry (%.5f → %.5f), triggering SL/TP logic",
               priceMovement / pipValue, entryPrice, bidPrice);

   double targetLevel = HedgePrice + (closingPointPips * pipValue);

   // Normalize the target level to proper digits
   targetLevel = NormalizeDouble(targetLevel, digits);

   // Determine if we should set SL or TP based on current price relative to target level
   bool setSL = (bidPrice > targetLevel); // If current price is above target, set as Stop Loss
   bool setTP = (bidPrice < targetLevel); // If current price is below target, set as Take Profit

   // Get current SL/TP values
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);

   // Modify the position
   bool success = false;

   if (setSL)
   {
      // Set Stop Loss at target level, keep existing TP
      success = trade.PositionModify(positionID, targetLevel, currentTP);

      if (success)
      {
         PrintFormat("✅ Stop Loss set at %.5f for bot position %I64u",
                     targetLevel, positionID);
         slTpAlreadySet = true;
      }
      else
      {
         PrintFormat("❌ Failed to set Stop Loss at %.5f. Error: %d",
                     targetLevel, GetLastError());
      }
   }
   else if (setTP)
   {
      // Set Take Profit at target level, keep existing SL
      success = trade.PositionModify(positionID, currentSL, targetLevel);

      if (success)
      {
         PrintFormat("✅ Take Profit set at %.5f for bot position %I64u",
                     targetLevel, positionID);
         slTpAlreadySet = true;
      }
      else
      {
         PrintFormat("❌ Failed to set Take Profit at %.5f. Error: %d",
                     targetLevel, GetLastError());
      }
   }
   else
   {
      // Edge case: price exactly equals target level
      PrintFormat("⚠ Price equals target level %.5f exactly, skipping SL/TP modification", targetLevel);
      slTpAlreadySet = true; // Set flag to avoid repeated attempts
   }
}