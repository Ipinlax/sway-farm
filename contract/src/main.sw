contract;

mod abi_structs;

use {
    abi_structs::*,
    std::{
        auth::msg_sender,
        block::timestamp,
        call_frames::{
            contract_id,
            msg_asset_id
        },
        asset_id::{
            construct_asset_id,
        },
        constants::ZERO_B256,
        context::msg_amount,
        logging::log,
        token::{
            mint_to,
            transfer,
        }
    },
};

enum InvalidError {
    NotEnoughTokens: u64,
    NotEnoughSeeds: u64,
    IncorrectAssetId: AssetId,
}

storage {
    players: StorageMap<Identity, Player> = StorageMap {},
    player_seeds: StorageMap<(Identity, FoodType), u64> = StorageMap {},
    planted_seeds: StorageMap<Identity, GardenVector> = StorageMap {},
    player_items: StorageMap<(Identity, FoodType), u64> = StorageMap {},
}

impl GameContract for Contract {
    #[storage(read, write)]
    fn new_player() {
        // get the message sender
        let sender = msg_sender().unwrap();

        // make sure the player doesn't already exist
        require(storage.players.get(sender).try_read().is_none(), "player already exists");

        // create a new player struct
        let new_player = Player {
            farming_skill: 1,
            total_value_sold: 0,
        };

        // add the player to storage
        storage.players.insert(sender, new_player);

        // initialize an empty garden 
        storage.planted_seeds.insert(sender, GardenVector::new());

        // each player gets some coins to start
        mint_to(sender, ZERO_B256, 1_000_000_000);
    }

    #[storage(read, write)]
    fn level_up() {
        // get the player with the message sender
        let mut player = storage.players.get(msg_sender().unwrap()).try_read().unwrap();

        // the max skill level is 10
        require(player.farming_skill < 10, "skill already max");

        let new_level = player.farming_skill + 1;

       // require that the total_value_sold > their new level squared * 3000
        let exp = new_level * new_level * 3_000_000;
        require(player.total_value_sold > exp, "not enough exp");

        // increase the player's skill level
        player.level_up_skill();

        // overwrite storage with the updated player struct
        storage.players.insert(msg_sender().unwrap(), player);
    }

    #[storage(read, write), payable]
    fn buy_seeds(food_type: FoodType, amount: u64) {
        let asset_id_1 = construct_asset_id(contract_id(), ZERO_B256);
        // let asset_id_2 = msg_asset_id();
        require(asset_id_1 == msg_asset_id(), InvalidError::IncorrectAssetId(msg_asset_id()));

        // get the amount of coins sent
        let message_amount = msg_amount();

        // set the price for each seed type 
        let mut price = u64::max();

        match food_type {
            FoodType::tomatoes => price = 750_000,
            // the compiler knows that other options would be unreachable
        }

        // the cost will be the amount of seeds * the price
        let cost = amount * price;

        // require that the amount is at least the price of the item
        require(message_amount >= cost, InvalidError::NotEnoughTokens(amount));

        let sender = msg_sender().unwrap();

        // check how many seeds the player currenly has
        let current_amount_option = storage.player_seeds.get((sender, food_type)).try_read();
        let mut current_amount = current_amount_option.unwrap_or(0);
        // add the current amount to the amount they are buying
        current_amount = current_amount + amount;

        // add seeds to inventory
        storage.player_seeds.insert((sender, food_type), current_amount);
    }

    #[storage(read, write)]
    fn plant_seed_at_index(food_type: FoodType, index: u64) {
        // get the sender
        let sender = msg_sender().unwrap();
        // require player has this many seeds
        let current_amount_option = storage.player_seeds.get((sender, food_type)).try_read();
        let current_amount = current_amount_option.unwrap_or(0);
        require(current_amount >= 1, InvalidError::NotEnoughSeeds(current_amount));

        let new_amount = current_amount - 1;
        //  update amount from player_seeds
        storage.player_seeds.insert((sender, food_type), new_amount);

        let mut vec = storage.planted_seeds.get(sender).try_read().unwrap();
        let food = Food {
            name: food_type,
            time_planted: Option::Some(timestamp()),
        };
        vec.plant_at_index(food, index);

        storage.planted_seeds.insert(sender, vec);
    }

    #[storage(read, write)]
    fn plant_seeds(food_type: FoodType, amount: u64, indexes: Vec<u64>) {
        // make sure the indexes length is equal to the amount
        require(indexes.len() == amount, "amount is not equal to indexes length");

        // get the sender
        let sender = msg_sender().unwrap();
        // require player has this many seeds
        let current_amount_option = storage.player_seeds.get((sender, food_type)).try_read();
        let current_amount = current_amount_option.unwrap_or(0);
        require(current_amount >= amount, InvalidError::NotEnoughSeeds(amount));
        let new_amount = current_amount - amount;
        //  update amount from player_seeds
        storage.player_seeds.insert((sender, food_type), new_amount);

        let mut count = 0;

        // add the amount of food structs to planted_seeds
        let mut vec = GardenVector::new();
        while count < amount {
            let food = Food {
                name: food_type,
                time_planted: Option::Some(timestamp()),
            };
            let index = indexes.get(count).unwrap();
            vec.plant_at_index(food, index);
            count += 1;
        }
        storage.planted_seeds.insert(sender, vec);
    }

    #[storage(read, write)]
    fn harvest(index: u64) {
        let sender = msg_sender().unwrap();
        let mut planted_seeds = storage.planted_seeds.get(sender).try_read().unwrap();
        let food = planted_seeds.inner[index].unwrap();
        let current_time = timestamp();
        let planted_time = food.time_planted.unwrap();

        // let one_min = 120;
        // use this for testing
        let time = 0;
        // let time = one_min * 5;
        let finish_time = planted_time + time;
        // require X days to pass
        require(current_time >= finish_time, "too early");

        // remove from planted_seeds
        planted_seeds.harvest_at_index(index);
        storage.planted_seeds.insert(sender, planted_seeds);

        // get current amount of items
        let current_amount = storage.player_items.get((sender, food.name)).try_read().unwrap_or(0);
        // add to player_items
        storage.player_items.insert((sender, food.name), current_amount + 1);
    }

    #[storage(read, write)]
    fn sell_item(food_type: FoodType, amount: u64) {
        let sender = msg_sender().unwrap();

        // make sure they have that amount
        let current_amount = storage.player_items.get((sender, food_type)).try_read().unwrap();
        require(current_amount >= amount, InvalidError::NotEnoughSeeds(amount));

        // update player_items 
        let new_amount = current_amount - amount;
        storage.player_items.insert((sender, food_type), new_amount);

        let mut amount_to_mint = 0;
        match food_type {
            FoodType::tomatoes => amount_to_mint = 7_500_000 * amount,
            // the compiler knows that other options would be unreachable
        }

        // increase the player's total_value_sold
        let mut player = storage.players.get(msg_sender().unwrap()).try_read().unwrap();
        player.increase_tvs(amount_to_mint);
        storage.players.insert(msg_sender().unwrap(), player);

        // send tokens
        mint_to(sender, ZERO_B256, amount_to_mint);
    }

    #[storage(read)]
    fn get_player(id: Identity) -> Option<Player> {
        storage.players.get(id).try_read()
    }

    #[storage(read)]
    fn get_seed_amount(id: Identity, item: FoodType) -> u64 {
        storage.player_seeds.get((id, item)).try_read().unwrap_or(0)
    }

    #[storage(read)]
    fn get_garden_vec(id: Identity) -> GardenVector {
        storage.planted_seeds.get(id).try_read().unwrap_or(GardenVector::new())
    }

    #[storage(read)]
    fn get_item_amount(id: Identity, item: FoodType) -> u64 {
        storage.player_items.get((id, item)).try_read().unwrap_or(0)
    }

    #[storage(read)]
    fn can_level_up(id: Identity) -> bool {
        // get the player 
        let player_result = storage.players.get(id).try_read();
        if player_result.is_none(){
            return false;
        }
        let player = player_result.unwrap();

        // the max skill level is 10
        if player.farming_skill < 10 {
            let new_level = player.farming_skill + 1;
            let exp = new_level * new_level * 3000;
            if player.total_value_sold > exp {
                true
            } else {
                false
            }
        } else {
            false
        }
    }

    #[storage(read)]
    fn can_harvest(index: u64) -> bool {
        let sender = msg_sender().unwrap();
        let planted_seeds_result = storage.planted_seeds.get(sender);
        if planted_seeds_result.try_read().is_none(){
            return false;
        }
        let planted_seeds = planted_seeds_result.try_read().unwrap();

        let food = planted_seeds.inner[index].unwrap();
        let current_time = timestamp();
        let planted_time = food.time_planted.unwrap();
        // let one_min: u64 = 120;
        // use this for testing
        let time = 0;
        // let time = one_min * 5;
        let finish_time = planted_time + time;
        if current_time >= finish_time {
            true
        } else {
            false
        }
    }

    #[storage(read, write)]
    fn buy_seeds_free(food_type: FoodType, amount: u64) {
        let sender = msg_sender().unwrap();

        // check how many seeds the player currenly has
        let mut current_amount = storage.player_seeds.get((sender, food_type)).try_read().unwrap_or(0);
        // add the current amount to the amount they are buying
        current_amount = current_amount + amount;

        // add seeds to inventory
        storage.player_seeds.insert((sender, food_type), current_amount);
    }
}
