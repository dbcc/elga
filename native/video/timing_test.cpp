#include "timing.h"
#include <cstdio>
#include <cstdlib>
#define REQUIRE(x) do { if(!(x)) { std::fprintf(stderr,"line %d: %s\n",__LINE__,#x); std::exit(1); } } while(0)
int main() {
    elga::Cadence c; const int64_t t=elga::second/60; c.reset(t);
    for(int n=0;n<150;++n) c.observe(n*t,n%2!=0);
    REQUIRE(c.factor==2);
    for(int n=150;n<400;++n) c.observe(n*t,true);
    REQUIRE(c.factor==2); // static scenes retain established moving cadence
    c.observe(400*t,false); c.observe(401*t,false);
    REQUIRE(c.factor==1); // changing content now arrives at capture rate
    for(int n=402;n<550;++n) c.observe(n*t,false);
    REQUIRE(c.factor==1);
    REQUIRE(c.observe(600*t,false)); REQUIRE(c.factor==1); // dropped input resets history
    REQUIRE(c.observe(0,false)); // timestamp restart
    c.reset(t); for(int n=0;n<200;++n) c.observe(n*t,true);
    REQUIRE(c.factor==1); // never infer 1 FPS from an unmoving image
    c.reset(t); for(int n=0;n<240;++n) c.observe(n*t,n%3!=0);
    REQUIRE(c.factor==3);
    REQUIRE(elga::displayCanDouble(119.88,elga::second*1001/60000));
    REQUIRE(!elga::displayCanDouble(60,t));
    elga::FixedCadence fixed;
    for(int64_t nominal : {t, elga::second*1001/60000}) {
        fixed.reset(nominal);
        REQUIRE(fixed.period==nominal*2);
        REQUIRE(elga::displayCanDouble(59.94,fixed.period));
        for(int n=0;n<300;++n) REQUIRE(fixed.accept(n*nominal)==(n%2==0));
        // Missing a callback does not change which subsequent samples we select.
        REQUIRE(fixed.accept(302*nominal)); REQUIRE(!fixed.accept(303*nominal));
        REQUIRE(fixed.accept(304*nominal)); REQUIRE(!fixed.accept(304*nominal));
        fixed.reset(nominal); REQUIRE(fixed.accept(0));
        REQUIRE(!fixed.accept(nominal)); REQUIRE(fixed.accept(2*nominal));
    }
    fixed.reset(elga::second/30); // native 30 FPS input is not halved again
    for(int n=0;n<30;++n) REQUIRE(fixed.accept(n*(elga::second/30)));
    elga::Timeline clock; clock.observe(100,5000);
    REQUIRE(clock.due(100+t,2*t)==5000+3*t);
    REQUIRE(clock.discontinuity(99,t)); REQUIRE(clock.discontinuity(100+2*t,t));
    REQUIRE(!clock.discontinuity(100+2*t,t,2*t)); // dropped HDMI repeat
    REQUIRE(!clock.discontinuity(100+4*t,t,2*t)); // lost whole game frame
    REQUIRE(clock.discontinuity(100+7*t,t,2*t)); // actual stall
    REQUIRE(clock.discontinuity(99,t,2*t)); // timestamp restart always resets
    fixed.reset(t); REQUIRE(fixed.accept(0));
    REQUIRE(fixed.accept(3*t)); REQUIRE(fixed.timestamp()==2*t); // replacement repeat
    REQUIRE(fixed.accept(4*t)); REQUIRE(fixed.timestamp()==4*t); // phase unchanged
    REQUIRE(!fixed.accept(5*t));
    clock.reset(); REQUIRE(!clock.discontinuity(0,t));
    std::puts("Cadence and timeline tests passed");
}
