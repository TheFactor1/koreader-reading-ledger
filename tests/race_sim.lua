--[[
Simulates readers against each rival to check the rival's tuning: a steady
reader (20 pages on weekdays, 45 at weekends, +-40%), one who slumps after
six weeks, and an irregular one who skips a third of days. 120 days each,
reading 9-midnight; 400-page books back to back.

Run from ledger.koplugin with KOReader's luajit:
  cd ledger.koplugin && <koreader>/luajit ../tests/race_sim.lua
"days won" is how often you were ahead of the rival over the week before
(what it tunes for); "books won" is races you finished first. V=1 prints
each book's finish.
--]]
package.path="./?.lua;"..package.path
package.loaded["ledger_data"]={readestAhead=function() return false end}
local Race=require("ledger_race")
local function newstore() return {t={},readSetting=function(s,k) return s.t[k] end,saveSetting=function(s,k,v) s.t[k]=v end,flush=function() end} end
local function reader(kind)
  -- pages a day for day index i (weekday from date)
  return function(t, i)
    local wd=os.date("*t",t).wday
    local base = (wd==1 or wd==7) and 45 or 20
    if kind=="slump" and i>40 then base=base*0.4 end
    if kind=="irregular" and math.random()<0.35 then return 0 end
    return math.max(0, math.floor(base*(0.6+0.8*math.random())))
  end
end
for _,kind in ipairs({"steady","slump","irregular"}) do
 for _,a in ipairs(Race.ANIMALS) do
  math.randomseed(7)
  local store=newstore()
  local days={}            -- date -> pages
  local t0=os.time{year=2026,month=6,day=1,hour=12}
  local read=reader(kind)
  local won,of=0,0
  local book_you, book_total, gaps, books_won, books=0,400,{},0,0
  local bookkey=1
  for i=0,119 do
    local tday=t0+i*86400
    -- the evening: you read between 21 and 23h
    local now=tday+9*3600   -- 21:00
    local habits={days={},hours={}}
    for d,n in pairs(days) do if d>=os.date("%Y-%m-%d",now-56*86400) then habits.days[d]=n end end
    for h=0,23 do habits.hours[h]=(h>=21 and h<=23) and 1/3 or 0 end
    local first; for d in pairs(habits.days) do if not first or d<first then first=d end end
    habits.first=first
    if not first then habits=nil end
    local m=Race.model(habits, now)
    Race.settle(store, m, a.id, now)
    local n=read(tday,i)
    days[os.date("%Y-%m-%d",tday)]=n
    book_you=math.min(book_total, book_you+n)
    local st=Race.state({hash="b"..bookkey,pages=book_total,pct=book_you/book_total},{today=n},store,"cat",a.id,m,now+3*3600-60)
    gaps[#gaps+1]=st.ahead
    if book_you>=book_total or st.rival_done then
      if os.getenv("V") then print("  book", bookkey, "you", book_you, "rival", st.rival_pages, "day", i) end
      books=books+1; if book_you>=book_total and not st.rival_done then books_won=books_won+1 end
      bookkey=bookkey+1; book_you=0
    end
  end
  local w,o=Race.record(store,a.id,60,t0+119*86400)
  local maxgap,sum=0,0; for _,g in ipairs(gaps) do maxgap=math.max(maxgap,math.abs(g)); sum=sum+math.abs(g) end
  print(string.format("%-9s %-8s days won %2d/%2d (%3d%%, target %d%%)  factor %.2f  books won %d/%d  mean|gap| %3d max %3d",
    kind,a.id,w,o,math.floor(100*w/math.max(1,o)),a.win*100,store.t.rival_form.factor[a.id] or 1,books_won,books,sum/#gaps,maxgap))
 end
end
