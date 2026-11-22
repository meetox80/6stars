import sys, os, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rpf import joaat

def candidates():
    here = os.path.dirname(os.path.abspath(__file__))
    out = set()
    for f in ("bonenames_packs.txt", "bonenames_anim.txt", "bonenames_extra.txt"):
        fp = os.path.join(here, f)
        if os.path.exists(fp):
            for l in open(fp):
                l = l.strip()
                if l:
                    out.add(l.split(" ", 1)[-1])
    parts = ["Root", "Pelvis", "Pelvis1", "Spine", "Neck", "Head", "Clavicle", "UpperArm", "Forearm", "Hand", "Thigh", "Calf", "Foot", "Toe", "Toe0", "Toe1",
             "ArmRoll", "ForeArmRoll", "ForearmRoll", "UpperArmRoll", "ThighRoll", "CalfRoll", "Elbow", "Knee", "Shoulder", "Wrist", "Breast", "Chest", "Butt", "Glute",
             "Bicep", "Tricep", "Pec", "Lat", "Trap", "Scapula", "Deltoid", "Ankle", "Heel", "Ball", "Hip", "Belly", "Stomach", "Collar", "Sternum", "Navel", "Jaw", "Eye", "Ear",
             "Finger", "Thumb", "Index", "Middle", "Ring", "Pinky", "Palm", "Weapon", "Prop", "Neck_Roll", "Hood", "Tail", "Hair", "Skirt", "Belt", "Pocket", "Hem", "Sleeve",
             "Bra", "Strap", "Cuff", "Collarbone", "Armpit", "Rib", "Ribs", "Waist", "Abdomen", "Groin", "Crotch", "Pelvis_Roll", "Neck_Twist", "UpperArm_Twist", "Forearm_Twist"]
    pre = ["SKEL_", "RB_", "MH_", "PH_", "IK_", "CH_", "IM_", "SPR_", "SM_", "FB_", "FACIAL_", "CL_", "SC_", "LOC_", "GRP_", "OH_", "XM_", "BR_", "PB_", "DM_", "BS_", "CS_", "MS_", "JT_", "HC_", "HM_", ""]
    side = ["L_", "R_", "C_", ""]
    suf = [""] + [str(i) for i in range(10)] + ["_%d" % i for i in range(10)] + ["%02d" % i for i in range(20)] + ["_%02d" % i for i in range(20)] + ["_%03d" % i for i in range(10)]
    for p in pre:
        for s in side:
            for part in parts:
                for x in suf:
                    out.add(p + s + part + x)
                    out.add(p + s + part + "Roll" + x)
    for s in ("L", "R"):
        for f in range(5):
            for j in range(4):
                out.add("SKEL_%s_Finger%d%d" % (s, f, j))
    return out

def table():
    d = {}
    for n in candidates():
        d.setdefault(joaat(n), n)
    return d
