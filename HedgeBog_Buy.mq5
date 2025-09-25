#property copyright "ChatGPT Assistant"
#property link      ""
#property version   "1.00"
#property strict

input double lots = 0.1;            // Lot size for buy
input int slippage = 10;             // Max allowed slippage in points

// Called when new price tick arrives
void OnTick()
{
    static bool order_sent = false;  // Track if order is already sent
    
    if (!order_sent)
    {
        order_sent = SendMarketBuyOrder(lots, slippage);
    }
}

// Function to send market buy order
bool SendMarketBuyOrder(double volume, int deviation)
{
    MqlTradeRequest request;
    MqlTradeResult result;

    ZeroMemory(request);
    ZeroMemory(result);

    request.action   = TRADE_ACTION_DEAL;                         // Market order execution
    request.symbol   = _Symbol;
    request.volume   = volume;
    request.type     = ORDER_TYPE_BUY;
    request.price    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);    // Buy at ASK price
    request.deviation= deviation;
    request.magic    = 123456;                                    // EA magic number
    request.comment  = "Market Buy Order";

    if(!OrderSend(request, result))
    {
        Print("OrderSend() failed with error: ", GetLastError());
        return false;
    }
    
    // OrderSend returned true, check result retcode
    if(result.retcode != TRADE_RETCODE_DONE)
    {
        Print("Trade request failed, retcode=", result.retcode);
        return false;
    }

    Print("Market Buy Order sent successfully. Order Ticket: ", result.order);

    // Now retrieve position details
    if(PositionSelect(_Symbol))
    {
        ulong position_ticket = PositionGetTicket(0);
        double position_volume = PositionGetDouble(POSITION_VOLUME);
        double position_price = PositionGetDouble(POSITION_PRICE_OPEN);
        Print("Position opened for symbol: ", _Symbol);
        Print("Position Ticket: ", position_ticket);
        Print("Position Volume: ", DoubleToString(position_volume, 2));
        Print("Position Open Price: ", DoubleToString(position_price, _Digits));
    }
    else
    {
        Print("PositionSelect failed - position not found.");
    }

    return true;
}

// OnTradeTransaction event handler - provides info about deals and orders
void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& request, const MqlTradeResult& result)
{
    // Log new deals
    if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
    {
        ulong deal_ticket = trans.deal;
        if(deal_ticket > 0)
        {
            double deal_volume = HistoryDealGetDouble(deal_ticket, DEAL_VOLUME);
            double deal_price = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
            ulong deal_position = HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);
            ENUM_DEAL_TYPE deal_type = (ENUM_DEAL_TYPE)HistoryDealGetInteger(deal_ticket, DEAL_TYPE);

            Print("New deal executed: Ticket=", deal_ticket,
                ", Type=", EnumToString(deal_type),
                ", Volume=", DoubleToString(deal_volume, 2),
                ", Price=", DoubleToString(deal_price, _Digits),
                ", Position ID=", deal_position);
        }
    }
}

// Utility function to convert ENUM_DEAL_TYPE to string
string EnumToString(ENUM_DEAL_TYPE type)
{
    switch(type)
    {
        case DEAL_TYPE_BUY: return "Buy";
        case DEAL_TYPE_SELL: return "Sell";
        case DEAL_TYPE_BALANCE: return "Balance";
        case DEAL_TYPE_CREDIT: return "Credit";
        case DEAL_TYPE_CHARGE: return "Charge";
        case DEAL_TYPE_CORRECTION: return "Correction";
        case DEAL_TYPE_BONUS: return "Bonus";
        default: return "Unknown";
    }
}
