//
//  ios_s.hpp
//  OpenTTD_iOS
//
//  Created by Christian Skaarup Enevoldsen on 22/06/2022.
//

#ifndef ios_s_hpp
#define ios_s_hpp

#include "sound_driver.hpp"

class SoundDriver_iOS : public SoundDriver {
public:
    const char *Start(const StringList &param) override;

    void Stop() override;
    const char *GetName() const override { return "ios"; }
};

class FSoundDriver_iOS : public DriverFactoryBase {
public:
    FSoundDriver_iOS() : DriverFactoryBase(Driver::DT_SOUND, 10, "ios", "iOS Sound Driver") {}
    Driver *CreateInstance() const override { return new SoundDriver_iOS(); }
};

#endif /* ios_s_hpp */
