"""
State registry + canonical schema metadata.

Adding a new state = (1) build its normalized parquet into data/parcels_<st>.parquet
with the canonical columns, (2) add a STATES entry below with its availability flags
and native-code labels. The app code never changes.
"""

# Canonical use categories shared across every state (the normalization target).
USE_CATEGORIES = [
    "commercial",
    "industrial",
    "institutional",
    "government",
    "agricultural",
    "utility_misc",
    "residential",
    "vacant",
]

# Categories that, for HVAC lead-gen, are the default selection.
HVAC_DEFAULT_CATEGORIES = ["commercial", "industrial", "institutional"]

# Florida DOR use-code labels (Rule 12D-8.008) for nicer display of native codes.
FL_DOR_LABELS = {
    "00": "Vacant residential", "01": "Single family", "02": "Mobile home",
    "03": "Multi-family 10+ units", "04": "Condominium", "05": "Cooperative",
    "06": "Retirement home", "07": "Misc residential", "08": "Multi-family <10 units",
    "09": "Residential common element",
    "10": "Vacant commercial", "11": "Stores, 1 story", "12": "Mixed use (store/office/res)",
    "13": "Department store", "14": "Supermarket", "15": "Regional shopping center",
    "16": "Community shopping center", "17": "Office, 1 story", "18": "Office, multi-story",
    "19": "Professional services bldg", "20": "Airport/terminal/marina",
    "21": "Restaurant/cafeteria", "22": "Drive-in restaurant", "23": "Financial institution",
    "24": "Insurance office", "25": "Repair service shop", "26": "Service station",
    "27": "Auto sales/repair/service", "28": "Parking lot / mobile home park",
    "29": "Wholesale/manufacturing outlet", "30": "Florist/greenhouse",
    "31": "Drive-in theater / open stadium", "32": "Enclosed theater/auditorium",
    "33": "Nightclub/bar", "34": "Bowling/skating/arena", "35": "Tourist attraction",
    "36": "Camp", "37": "Race track", "38": "Golf course", "39": "Hotel/motel",
    "40": "Vacant industrial", "41": "Light manufacturing", "42": "Heavy industrial",
    "43": "Lumber yard/sawmill", "44": "Packing plant", "45": "Cannery/bottler/distillery",
    "46": "Other food processing", "47": "Mineral processing", "48": "Warehouse/distribution",
    "49": "Open storage / junk yard",
    "70": "Vacant institutional", "71": "Church", "72": "Private school/college",
    "73": "Private hospital", "74": "Home for the aged", "75": "Orphanage / non-profit",
    "76": "Mortuary/cemetery", "77": "Club/lodge/union hall", "78": "Sanitarium/rest home",
    "79": "Cultural organization",
    "81": "Military", "82": "Forest/park/recreation", "83": "Public county school",
    "84": "College (state)", "85": "Hospital (state)", "86": "County government",
    "87": "State government", "88": "Federal government", "89": "Municipal government",
    "90": "Leasehold interest", "91": "Utility (gas/electric/telecom/water)",
    "92": "Mining/petroleum land", "93": "Subsurface rights", "94": "Right-of-way",
    "95": "Rivers/lakes/submerged", "96": "Sewage/waste/borrow pit",
    "97": "Outdoor recreation/parkland", "98": "Centrally assessed", "99": "Acreage non-ag",
}

STATES = {
    "FL": {
        "label": "Florida",
        "data": "data/parcels_fl.parquet",
        "vintage": "2025 Final Tax Roll",
        "source": "Florida Dept. of Revenue (DOR) NAL roll — all 67 counties",
        # availability flags drive which filters are enabled for this state
        "available": {
            "bldg_sqft": True,
            "num_buildings": True,
            "year_built": True,
            "land_sqft": True,
            "market_value": True,
        },
        "native_labels": FL_DOR_LABELS,
        "native_code_name": "DOR use code",
    },
    # "TX": {  # future adapter — same canonical columns, different source + crosswalk
    #     "label": "Texas",
    #     "data": "data/parcels_tx.parquet",
    #     "vintage": "2025 CAD certified",
    #     "source": "Texas county appraisal districts",
    #     "available": {"bldg_sqft": False, "num_buildings": False, ...},
    #     "native_labels": {...},
    #     "native_code_name": "State class code",
    # },
}
