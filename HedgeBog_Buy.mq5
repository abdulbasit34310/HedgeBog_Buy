#property copyright "Abdul Basit"
#property link      "https://www.mql5.com"
#property version   "1.02"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;
CPositionInfo position;
COrderInfo order;

// --- Global Variables ---
ulong buyStopTicket = 0;        // Track our Buy Stop order ticket
bool   hasOpenBuyPosition = false;
bool   hasPendingOrder = false;
string currentSymbol = Symbol();
datetime pause_until = 0;
datetime last_print_time = 0;

// SL Hit Detection Variables
ulong tracked_position_tickets[10]; // Track up to 10 buy positions
int   tracked_positions_count = 0;

input double HedgePrice      = 4425.0;
input double Lots            = 1;
input double afterOrderDelay = 10;
input double afterSLDelay    = 10;

int OnInit()
{
   PrintFormat("Hedge Bot EA initialized.");
   return (INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Print("Hedge Bot EA deinitialized. Reason: ", reason);
}

// ------------------------------------
// Tick Handling
// ------------------------------------
void OnTick()
{
   if (IsSkippingTicks())
   {
      if (TimeCurrent() != last_print_time)
      {
         last_print_time = TimeCurrent();
         PrintFormat("⏳ Ticking stopped... %d sec left",
                     (int)(pause_until - TimeCurrent()));
      }
      return;
   }

   double bidPrice = SymbolInfoDouble(currentSymbol, SYMBOL_BID);

   // Check open positions
   Check_Open_Position();

   // Main trade logic
   if (!hasOpenBuyPosition && !hasPendingOrder && bidPrice >= HedgePrice)
   {
      Market_Buy();
   }
   else if (!hasOpenBuyPosition && !hasPendingOrder && bidPrice <= HedgePrice)
   {
      Buy_Stop();
   }
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   ulong order_ticket = trans.order;
   ulong deal_ticket  = trans.deal;

   // 1️⃣ Buy Stop executed into a deal
   if (trans.type == TRADE_TRANSACTION_DEAL_ADD && order_ticket == buyStopTicket)
   {
      PrintFormat("Buy Stop (ticket %I64u) executed via deal %I64u. Skipping ticks for %d seconds.",
                  buyStopTicket, deal_ticket, (int)afterOrderDelay);

      buyStopTicket = 0;
      hasPendingOrder = false;
      
      // Skip ticks first, then add SL
      SkipTicksFor((int)afterOrderDelay);
      
      // Get the position ticket from the deal and start tracking it
      if (trans.position != 0)
      {
         AddPositionToTracking(trans.position);
         // Add SL after a brief delay to ensure position is fully processed
         datetime sl_time = TimeCurrent() + afterOrderDelay + 1;
         AddDelayedSL(trans.position, sl_time);
      }
   }

   // 2️⃣ BUY Stop deleted/canceled/expired
   if (trans.type == TRADE_TRANSACTION_ORDER_DELETE && order_ticket == buyStopTicket)
   {
      PrintFormat("Buy Stop (ticket %I64u) canceled/expired. Clearing tracking.", buyStopTicket);
      buyStopTicket = 0;
      hasPendingOrder = false;
   }

   // 3️⃣ (Optional) Confirmation of our placed Buy Stop
   if (trans.type == TRADE_TRANSACTION_ORDER_ADD && request.type == ORDER_TYPE_BUY_STOP)
   {
      PrintFormat("Buy Stop order confirmed by server. Ticket: %I64u", order_ticket);
   }

   // 4️⃣ Check for SL hit detection
   SL_Hit_Detection(trans, request, result);
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
}

void Market_Buy()
{
   if (trade.Buy(Lots, currentSymbol, 0, 0, 0, "Market_Buy"))
   {
      hasPendingOrder = false;
      ulong deal_ticket = trade.ResultDeal();
      PrintFormat("Market_Buy placed. Deal ticket: %I64u", deal_ticket);
      
      // Skip ticks first
      SkipTicksFor((int)afterOrderDelay);
      
      // Schedule SL addition after the skip period - we'll find position by deal
      datetime sl_time = TimeCurrent() + afterOrderDelay + 1;
      AddDelayedSLByDeal(deal_ticket, sl_time);
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
      PrintFormat("📌 Buy_Stop placed at %.5f. Ticket: %I64u", HedgePrice, buyStopTicket);
   }
   else
   {
      PrintFormat("❌ Failed Buy_Stop. Error: %d", GetLastError());
   }
}

bool SL_Adding(ulong position_ticket)
{
   // 1. Verify position exists and select it by ticket
   if (!PositionSelectByTicket(position_ticket))
   {
      PrintFormat("❌ SL_Adding: Position ticket %I64u not found", position_ticket);
      return false;
   }
   
   // 2. Verify it's our symbol and it's a BUY position
   if (PositionGetString(POSITION_SYMBOL) != currentSymbol)
   {
      PrintFormat("❌ SL_Adding: Position %I64u is not for symbol %s", position_ticket, currentSymbol);
      return false;
   }
   
   if (PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY)
   {
      PrintFormat("❌ SL_Adding: Position %I64u is not a BUY position", position_ticket);
      return false;
   }
   
   // 3. Check if SL already exists
   double current_sl = PositionGetDouble(POSITION_SL);
   if (current_sl > 0)
   {
      PrintFormat("ℹ️ SL_Adding: Position %I64u already has SL at %.5f", position_ticket, current_sl);
      return true; // Consider this successful since SL exists
   }
   
   // 4. Calculate SL price (one pip above HedgePrice for BUY position)
   double point = SymbolInfoDouble(currentSymbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(currentSymbol, SYMBOL_DIGITS);
   double sl_price = NormalizeDouble(HedgePrice - (10 * point), digits); // 1 pip = 10 points for 5-digit brokers
   
   // 5. Verify SL is valid for BUY position (SL should be below current price)
   double current_price = PositionGetDouble(POSITION_PRICE_CURRENT);

   if (sl_price >= current_price)
   {
      PrintFormat("⚠️ SL_Adding: SL %.5f >= current_price %.5f", 
                  sl_price, current_price);
      if (trade.PositionModify(position_ticket, sl_price, 0))
      {
         PrintFormat("✅ SL_Adding: Successfully added TP %.5f to position %I64u", sl_price, position_ticket);
         return true;
      }
      else
      {
         int error = GetLastError();
         PrintFormat("❌ SL_Adding: Failed to add TP to position %I64u. Error: %d", position_ticket, error);
         return false;
      }
   }
   else {
      if (trade.PositionModify(position_ticket, sl_price, 0))
      {
         PrintFormat("✅ SL_Adding: Successfully added SL %.5f to position %I64u", sl_price, position_ticket);
         return true;
      }
      else
      {
         int error = GetLastError();
         PrintFormat("❌ SL_Adding: Failed to add SL to position %I64u. Error: %d", position_ticket, error);
         return false;
      } 
   }
   
}

// Global variables for delayed SL processing
struct DelayedSLRequest
{
   ulong position_ticket;
   datetime execute_time;
   bool use_deal_lookup; // Flag to indicate if we need to lookup position by deal
   ulong deal_ticket;    // Deal ticket for lookup
};

DelayedSLRequest pending_sl_requests[10]; // Array to store pending SL requests
int pending_sl_count = 0;

void AddDelayedSL(ulong position_ticket, datetime execute_time)
{
   if (pending_sl_count < ArraySize(pending_sl_requests))
   {
      pending_sl_requests[pending_sl_count].position_ticket = position_ticket;
      pending_sl_requests[pending_sl_count].execute_time = execute_time;
      pending_sl_requests[pending_sl_count].use_deal_lookup = false;
      pending_sl_requests[pending_sl_count].deal_ticket = 0;
      pending_sl_count++;
      PrintFormat("📋 Scheduled SL addition for position %I64u at %s", 
                  position_ticket, TimeToString(execute_time, TIME_SECONDS));
   }
}

void AddDelayedSLByDeal(ulong deal_ticket, datetime execute_time)
{
   if (pending_sl_count < ArraySize(pending_sl_requests))
   {
      pending_sl_requests[pending_sl_count].position_ticket = 0;
      pending_sl_requests[pending_sl_count].execute_time = execute_time;
      pending_sl_requests[pending_sl_count].use_deal_lookup = true;
      pending_sl_requests[pending_sl_count].deal_ticket = deal_ticket;
      pending_sl_count++;
      PrintFormat("📋 Scheduled SL addition for deal %I64u at %s", 
                  deal_ticket, TimeToString(execute_time, TIME_SECONDS));
   }
}

ulong GetPositionTicketFromDeal(ulong deal_ticket)
{
   // Select the deal by ticket
   if (HistoryDealSelect(deal_ticket))
   {
      // Get position ticket from deal properties
      ulong position_ticket = HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);
      PrintFormat("🔍 Found position ticket %I64u for deal %I64u", position_ticket, deal_ticket);
      // Also add to tracking when we find it from deal
      AddPositionToTracking(position_ticket);
      return position_ticket;
   }
   else
   {
      PrintFormat("❌ Failed to select deal %I64u", deal_ticket);
      return 0;
   }
}

void ProcessDelayedSL()
{
   datetime current_time = TimeCurrent();
   
   for (int i = pending_sl_count - 1; i >= 0; i--)
   {
      if (current_time >= pending_sl_requests[i].execute_time)
      {
         ulong ticket = 0;
         
         if (pending_sl_requests[i].use_deal_lookup)
         {
            // Find position ticket from deal ticket
            ticket = GetPositionTicketFromDeal(pending_sl_requests[i].deal_ticket);
            if (ticket == 0)
            {
               PrintFormat("❌ Could not find position for deal %I64u", pending_sl_requests[i].deal_ticket);
               // Remove failed request
               for (int j = i; j < pending_sl_count - 1; j++)
               {
                  pending_sl_requests[j] = pending_sl_requests[j + 1];
               }
               pending_sl_count--;
               continue;
            }
         }
         else
         {
            ticket = pending_sl_requests[i].position_ticket;
         }
         
         PrintFormat("⏰ Processing delayed SL for position %I64u", ticket);
         
         SL_Adding(ticket);
         
         // Remove processed request by shifting array elements
         for (int j = i; j < pending_sl_count - 1; j++)
         {
            pending_sl_requests[j] = pending_sl_requests[j + 1];
         }
         pending_sl_count--;
      }
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
   // Process delayed SL requests even when skipping ticks
   if (pending_sl_count > 0)
   {
      ProcessDelayedSL();
   }
   
   return (TimeCurrent() < pause_until);
}


void AddPositionToTracking(ulong position_ticket)
{
   // Check if already tracking this position
   for (int i = 0; i < tracked_positions_count; i++)
   {
      if (tracked_position_tickets[i] == position_ticket)
      {
         PrintFormat("ℹ️ Position %I64u already being tracked", position_ticket);
         return;
      }
   }
   
   // Add to tracking array if space available
   if (tracked_positions_count < ArraySize(tracked_position_tickets))
   {
      tracked_position_tickets[tracked_positions_count] = position_ticket;
      tracked_positions_count++;
      PrintFormat("📍 Started tracking position %I64u for SL hits", position_ticket);
   }
   else
   {
      PrintFormat("⚠️ Cannot track more positions. Array full!");
   }
}

void RemovePositionFromTracking(ulong position_ticket)
{
   for (int i = 0; i < tracked_positions_count; i++)
   {
      if (tracked_position_tickets[i] == position_ticket)
      {
         // Shift remaining elements
         for (int j = i; j < tracked_positions_count - 1; j++)
         {
            tracked_position_tickets[j] = tracked_position_tickets[j + 1];
         }
         tracked_positions_count--;
         PrintFormat("🗑️ Stopped tracking position %I64u", position_ticket);
         break;
      }
   }
}

bool IsPositionBeingTracked(ulong position_ticket)
{
   for (int i = 0; i < tracked_positions_count; i++)
   {
      if (tracked_position_tickets[i] == position_ticket)
      {
         return true;
      }
   }
   return false;
}

void SL_Hit_Detection(const MqlTradeTransaction &trans, 
                      const MqlTradeRequest &request, 
                      const MqlTradeResult &result)
{
   // We detect SL hits by monitoring DEAL_ADD transactions
   if (trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong deal_ticket = trans.deal;
      ulong position_ticket = trans.position;
      
      // Check if this is a position we're tracking
      if (!IsPositionBeingTracked(position_ticket))
      {
         return; // Not our position, ignore
      }
      
      // Select the deal to get more information
      if (HistoryDealSelect(deal_ticket))
      {
         ENUM_DEAL_TYPE deal_type = (ENUM_DEAL_TYPE)HistoryDealGetInteger(deal_ticket, DEAL_TYPE);
         ENUM_DEAL_REASON deal_reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal_ticket, DEAL_REASON);
         string symbol = HistoryDealGetString(deal_ticket, DEAL_SYMBOL);
         double volume = HistoryDealGetDouble(deal_ticket, DEAL_VOLUME);
         double price = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
         double profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);
         
         // Check if this is a BUY deal (closing our BUY position) due to SL
         if (deal_type == DEAL_TYPE_SELL && 
             deal_reason == DEAL_REASON_SL && 
             symbol == currentSymbol)
         {
            PrintFormat("🎯 SL HIT DETECTED! Position %I64u closed by SL", position_ticket);
            PrintFormat("   Deal: %I64u | Price: %.5f | Volume: %.2f | Profit: %.2f", 
                       deal_ticket, price, volume, profit);
            
            // Stop tracking this position since it's closed
            RemovePositionFromTracking(position_ticket);
            
            // Call your custom SL hit handler
            OnSLHit(position_ticket, deal_ticket, price, volume, profit);
            SkipTicksFor((int)afterSLDelay);
         }
      }
   }
}

void OnSLHit(ulong position_ticket, ulong deal_ticket, double close_price, 
             double volume, double profit)
{
   // Custom handler for when SL is hit
   // You can add your custom logic here
   
   // PrintFormat("🚨 SL HIT HANDLER TRIGGERED");
   // PrintFormat("   Position: %I64u", position_ticket);
   // PrintFormat("   Deal: %I64u", deal_ticket);
   // PrintFormat("   Close Price: %.5f", close_price);
   // PrintFormat("   Volume: %.2f", volume);
   // PrintFormat("   Profit/Loss: %.2f", profit);
   
   // Example: You could place a new hedge order, send notifications, etc.
   // PlaceNewHedgeOrder();
   // SendNotification();
   
   // PrintFormat("💡 Add your custom SL hit logic in OnSLHit() function");
}