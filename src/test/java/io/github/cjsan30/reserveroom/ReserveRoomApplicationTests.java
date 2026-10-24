package io.github.cjsan30.reserveroom;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;

@Import(TestcontainersConfiguration.class)
@SpringBootTest
class ReserveRoomApplicationTests {

	@Test
	void contextLoads() {
	}

}
