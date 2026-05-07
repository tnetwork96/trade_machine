//+------------------------------------------------------------------+
//|                                              Moving Averages.mq5 |
//|                             Copyright 2000-2026, MetaQuotes Ltd. |
//|                                                     www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2000-2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <Trade\Trade.mqh>

// ==== Tham số người dùng (có thể chỉnh trong EA inputs) ====
// Số nến trước đó cần kiểm tra (không tính nến hiện tại)
input int  InpLookbackBars  = 50;    
// Sai số chạm vùng giá (points) để xác định có chạm
input int  InpZonePoints    = 3;    
// Độ rộng vùng vẽ (points) cho 2 đường song song
input int  InpDrawPoints    = 3;     
// Số nến LIỀN KỀ phải chạm vùng giá mới đủ điều kiện
input int  InpConsecutiveBars = 10;  
// Khoảng cách vượt xa vùng để kích hoạt lệnh (points)
input int  InpBreakoutDistancePoints = 0;
// Khối lượng vào lệnh
input double InpLotSize = 0.01;
// Stop Loss (points), 0 = không đặt
input int  InpStopLossPoints = 0;
// Take Profit (points), 0 = không đặt
input int  InpTakeProfitPoints = 0;

// Lưu giá vùng gần nhất khi đủ điều kiện
bool g_zone_active = false;
double g_zone_price = 0.0;
double g_zone_low = 0.0;
double g_zone_high = 0.0;
datetime g_zone_left_time = 0;
datetime g_zone_right_time = 0;
// Đối tượng trade để đặt lệnh
CTrade g_trade;

// Kiểm tra chuỗi nến liền kề ngay trước nến anchor.
// - Anchor = nến ngay trước tick hiện tại (shift = 1) -> rates[0].
// - Chỉ khi đủ số nến liền kề chạm vùng giá mới vẽ.
// - Trả về giá vùng (zone_low/zone_high) và thời gian để vẽ đoạn.
bool PreviousBarsTouchedZone(const int lookback_bars,
                              const int zone_points,
                              const int draw_points,
                              const int consecutive_bars,
                              double &zone_low,
                              double &zone_high,
                              double &zone_price,
                              datetime &left_time,
                              datetime &right_time)
{
   // Lấy dữ liệu nến liền kề từ nến vừa đóng cửa nhất (shift = 1)
   MqlRates rates[];
   const int need = MathMax(lookback_bars, 2);
   const int copied = CopyRates(_Symbol, _Period, 1, need, rates);

   if(copied < 2)
      return false;

   // Đặt rates[0] là nến gần nhất (shift=1)
   ArraySetAsSeries(rates, true); 
   // Đỉnh giá cao và thấp của nến anchor
   const double anchor_high = rates[0].high; 
   const double anchor_low = rates[0].low;   
   // Sai số chạm vùng giá
   const double tolerance = zone_points * _Point;      
   // Độ rộng vùng vẽ hẹp
   const double draw_tolerance = draw_points * _Point; 
   // Số nến liền kề tối thiểu
   const int required = MathMax(consecutive_bars, 1);  
   if(copied < required + 1)
      return false;

   // Kiểm tra chuỗi liền kề chạm quanh anchor_high
   int touches = 0;
   for(int i = 1; i <= required; ++i)
   {
      // Kiểm tra chạm vùng giá
      if(MathAbs(rates[i].high - anchor_high) <= tolerance ||
         MathAbs(rates[i].low - anchor_high) <= tolerance)
      {
         touches++;
      }
      else
      {
         touches = 0;
         break;
      }
   }

   if(touches >= required)
   {
      // Vẽ đoạn song song
      zone_low = anchor_high - draw_tolerance;
      zone_high = anchor_high + draw_tolerance;
      zone_price = anchor_high;
      // Đoạn vẽ chỉ trong khoảng nến liền kề -> từ nến cũ nhất đến anchor
      left_time = rates[required].time;
      right_time = rates[0].time;
      return true;
   }

   // Kiểm tra chuỗi liền kề chạm quanh anchor_low
   touches = 0;
   for(int i = 1; i <= required; ++i)
   {
      // Kiểm tra chạm vùng giá
      if(MathAbs(rates[i].high - anchor_low) <= tolerance ||
         MathAbs(rates[i].low - anchor_low) <= tolerance)
      {
         touches++;
      }
      else
      {
         touches = 0;
         break;
      }
   }

   if(touches >= required)
   {
      // Vẽ đoạn song song
      zone_low = anchor_low - draw_tolerance;
      zone_high = anchor_low + draw_tolerance;
      zone_price = anchor_low;
      left_time = rates[required].time;
      right_time = rates[0].time;
      return true;
   }

   return false;
}

// Đặt lệnh khi nến đóng cửa vượt xa vùng giá.
// - Đóng trên vùng + khoảng cách: SELL thị trường.
// - Đóng dưới vùng - khoảng cách: BUY thị trường.
bool CheckBreakoutTrade(const bool zone_active,
                        const double zone_low,
                        const double zone_high)
{
   static datetime last_signal_time = 0;
   static int last_signal_side = 0; // 1 = trên vùng, -1 = dưới vùng

   if(!zone_active)
   {
      last_signal_time = 0;
      last_signal_side = 0;
      return false;
   }

   MqlRates last_bar[];
   if(CopyRates(_Symbol, _Period, 1, 1, last_bar) < 1)
      return false;
   ArraySetAsSeries(last_bar, true);

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   const datetime bar_time = last_bar[0].time;
   const double bar_high = last_bar[0].high;
   const double bar_low = last_bar[0].low;
   const double bar_close = last_bar[0].close;
   const double breakout_distance = InpBreakoutDistancePoints * _Point;

   // Nếu đã xử lý nến này rồi thì không lặp lại
   if(bar_time == last_signal_time)
      return false;

   // Nếu đã có lệnh đang mở thì không vào thêm
   if(PositionSelect(_Symbol))
      return false;

   double sl = 0.0;
   double tp = 0.0;

   // Nến đóng cửa vượt xa phía trên vùng -> SELL thị trường
   if(bar_close > zone_high + breakout_distance)
   {
      const double entry = tick.bid;
      tp = zone_high; // TP về mép trên vùng
      if(tp >= entry)
      {
         Print("TP tại vùng nằm trên giá sell, bỏ qua lệnh.");
         last_signal_time = bar_time;
         last_signal_side = 1;
         return false;
      }
      if(InpStopLossPoints > 0)
         sl = entry + InpStopLossPoints * _Point;

      if(g_trade.Sell(InpLotSize, _Symbol, entry, sl, tp, "ZoneBreakoutSell"))
      {
         last_signal_time = bar_time;
         last_signal_side = 1;
         return true;
      }

      last_signal_time = bar_time;
      last_signal_side = 1;
      return false;
   }

   // Nến đóng cửa vượt xa phía dưới vùng -> BUY thị trường
   if(bar_close < zone_low - breakout_distance)
   {
      const double entry = tick.ask;
      tp = zone_low; // TP về mép dưới vùng
      if(tp <= entry)
      {
         Print("TP tại vùng nằm dưới giá buy, bỏ qua lệnh.");
         last_signal_time = bar_time;
         last_signal_side = -1;
         return false;
      }
      if(InpStopLossPoints > 0)
         sl = entry - InpStopLossPoints * _Point;

      if(g_trade.Buy(InpLotSize, _Symbol, entry, sl, tp, "ZoneBreakoutBuy"))
      {
         last_signal_time = bar_time;
         last_signal_side = -1;
         return true;
      }

      last_signal_time = bar_time;
      last_signal_side = -1;
      return false;
   }

   return false;
}

// Vẽ đoạn ngang trong khoảng thời gian đủ điều kiện (không kéo dài về trái/phải).
void DrawZoneSegment(const string name,
                     const datetime left_time,
                     const datetime right_time,
                     const double price)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_TREND, 0, left_time, price, right_time, price);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrLime);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
   }
   else
   {
      ObjectMove(0, name, 0, left_time, price);
      ObjectMove(0, name, 1, right_time, price);
   }
}

void OnTick()
{
   // Khi đang có lệnh mở thì không tìm tín hiệu mới, giữ nguyên vùng hiện tại
   if(PositionSelect(_Symbol))
   {
      if(g_zone_active)
      {
         DrawZoneSegment("TickZoneHigh", g_zone_left_time, g_zone_right_time, g_zone_high);
         DrawZoneSegment("TickZoneLow", g_zone_left_time, g_zone_right_time, g_zone_low);
      }
      return;
   }

   // Kiểm tra điều kiện và vẽ 2 đoạn song song khi đủ điều kiện
   double zone_low = 0.0;
   double zone_high = 0.0;
   double zone_price = 0.0;
   datetime left_time = 0;
   datetime right_time = 0;
   const bool touched = PreviousBarsTouchedZone(
      InpLookbackBars,
      InpZonePoints,
      InpDrawPoints,
      InpConsecutiveBars,
      zone_low,
      zone_high,
      zone_price,
      left_time,
      right_time
   );

   if(touched)
   {
      g_zone_active = true;
      g_zone_price = zone_price;
      g_zone_low = zone_low;
      g_zone_high = zone_high;
      g_zone_left_time = left_time;
      g_zone_right_time = right_time;
      DrawZoneSegment("TickZoneHigh", left_time, right_time, zone_high);
      DrawZoneSegment("TickZoneLow", left_time, right_time, zone_low);
      PrintFormat("Da co tick truoc do cham cung vung gia. Gia vung: %s",
                  DoubleToString(g_zone_price, _Digits));
   }
   else
   {
      // Giữ vùng cũ trên biểu đồ khi chưa có lệnh
      if(g_zone_active)
      {
         DrawZoneSegment("TickZoneHigh", g_zone_left_time, g_zone_right_time, g_zone_high);
         DrawZoneSegment("TickZoneLow", g_zone_left_time, g_zone_right_time, g_zone_low);
      }
   }

   // Kiểm tra breakout và đặt lệnh theo hướng thoát vùng
   CheckBreakoutTrade(g_zone_active, g_zone_low, g_zone_high);
}

