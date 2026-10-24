package io.github.cjsan30.reserveroom;

import org.springframework.boot.SpringApplication;

public class TestReserveRoomApplication {

	public static void main(String[] args) {
		SpringApplication.from(ReserveRoomApplication::main).with(TestcontainersConfiguration.class).run(args);
	}

}
